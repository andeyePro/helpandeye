import { configured, push } from "./apns.js";
import { authenticate, GroupRelay, KEEP_MS, MAX_MEMBERS_REQUEST, MAX_REQUEST, Meter as MeterLogic, RelayError, unb64 } from "./relay.js";

// Routes:
//   PUT  /g/<groupId>/members          coordinator sends the member list (public keys only)
//   POST /g/<groupId>/messages         a member posts a sealed message
//   GET  /g/<groupId>/messages?after=n a member fetches sealed messages after sequence n
//   PUT  /g/<groupId>/push             a member registers its push token
// A message may carry "wake": "call" (a visible push to the others) or "quiet" (wakes their app).
// Every request carries X-HelpA-Key, X-HelpA-Time and X-HelpA-Signature, checked here before any
// group sees the request.
// Every response carries X-HelpA-Allowance-Low: 1 when the free daily allowance is nearly used.

const GROUP_ID = /^[A-Za-z0-9_-]{16,64}$/;
// Workers on the free plan may make 50 subrequests per invocation, and each push is one. One is
// kept back for the group's rate limit check.
export const SUBREQUESTS = 50;
export const PUSH_BATCH = SUBREQUESTS - 1;

// The meter's last answer. It is asked after the reply, so a slow or failing meter never holds one up.
let low = false;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const m = url.pathname.match(/^\/g\/([^/]+)\/(members|messages|push)$/);
    if (!m || !GROUP_ID.test(m[1])) return json(404, { error: "not found" });
    let response;
    try {
      if (!(await allowed(env.IP_LIMIT, request.headers.get("CF-Connecting-IP") ?? ""))) throw new RelayError(429, "too many requests");
      const limit = m[2] === "members" ? MAX_MEMBERS_REQUEST : MAX_REQUEST;
      if (Number(request.headers.get("Content-Length")) > limit) throw new RelayError(413, "too large");
      const body = await readBody(request, limit);
      await authenticate({
        method: request.method,
        path: url.pathname + url.search,
        key: request.headers.get("X-HelpA-Key") ?? "",
        timestamp: request.headers.get("X-HelpA-Time") ?? "",
        signature: request.headers.get("X-HelpA-Signature") ?? "",
        body,
      });
      const stub = env.GROUPS.get(env.GROUPS.idFromName(m[1]));
      response = await stub.fetch(request.url, { method: request.method, headers: request.headers, body: body || undefined });
      ctx.waitUntil(count(env));
    } catch (e) {
      if (!(e instanceof RelayError)) throw e;
      response = json(e.status, { error: e.message });
    }
    const out = new Response(response.body, response);
    if (low) out.headers.set("X-HelpA-Allowance-Low", "1");
    return out;
  },
};

async function count(env) {
  try {
    const meter = env.METER.get(env.METER.idFromName("all"));
    low = (await (await meter.fetch("https://meter/add", { method: "POST" })).json()).low === true;
  } catch {
    // Keeps the last answer.
  }
}

// Reads at most `limit` bytes, whatever Content-Length said.
async function readBody(request, limit) {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (let r = await reader.read(); !r.done; r = await reader.read()) {
    size += r.value.byteLength;
    if (size > limit) {
      await reader.cancel();
      throw new RelayError(413, "too large");
    }
    chunks.push(r.value);
  }
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) { bytes.set(c, at); at += c.byteLength; }
  return new TextDecoder().decode(bytes);
}

// A Cloudflare rate limiting binding. Absent (as in local tests) or failing, nothing is limited:
// a call for help is never refused because the limiter is down.
async function allowed(limiter, key) {
  if (!limiter) return true;
  try {
    return (await limiter.limit({ key })).success !== false;
  } catch {
    return true;
  }
}

export class Group {
  constructor(state, env) {
    this.relay = new GroupRelay(state.storage);
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    try {
      const url = new URL(request.url);
      const [, , groupId, kind] = url.pathname.split("/");
      const body = await request.text();
      // Only the Worker reaches a group, and it has checked this key's signature.
      const key = request.headers.get("X-HelpA-Key") ?? "";
      // Counted for members only, so someone outside the group cannot use up its limit.
      if ((await this.relay.isMember(key)) && !(await allowed(this.env.GROUP_LIMIT, groupId))) throw new RelayError(429, "too many requests for this group");
      if (kind === "members" && request.method === "PUT") {
        const list = JSON.parse(body);
        // A new group keeps state for whoever registers it, so each address may register only a few.
        const registering = !(await this.relay.members()) && list?.primary === key;
        if (registering && !(await allowed(this.env.REGISTER_LIMIT, request.headers.get("CF-Connecting-IP") ?? ""))) throw new RelayError(429, "too many new groups");
        const id = groupId.replace(/-/g, "+").replace(/_/g, "/");
        await this.relay.setMembers(key, list, unb64(id + "=".repeat((4 - (id.length % 4)) % 4)));
        return json(200, { ok: true });
      }
      if (kind === "messages" && request.method === "POST") {
        const msg = JSON.parse(body);
        if (!msg || typeof msg !== "object") throw new RelayError(400, "bad message");
        const wakes = msg.wake === "call" || msg.wake === "quiet";
        const mayWake = await this.relay.limit(key, wakes);
        const seq = await this.relay.post(key, msg.sealed);
        if ((await this.state.storage.getAlarm()) === null) await this.state.storage.setAlarm(Date.now() + KEEP_MS);
        // Told when nobody was woken, so the client asks again on its resend.
        let reason;
        if (wakes && !mayWake) reason = "too many wakes";
        else if (wakes && configured(this.env)) {
          const targets = await this.relay.pushTargets(key);
          if (targets.length > PUSH_BATCH) {
            await this.relay.queuePushes(seq, { sender: key, kind: msg.wake, sealed: msg.sealed, tokens: targets.slice(PUSH_BATCH).map((t) => t.token) });
            await this.state.storage.setAlarm(Date.now());
          }
          if (targets.length && !(await this.wake(targets.slice(0, PUSH_BATCH), msg.wake, msg.sealed))) reason = "no push got through";
        }
        return json(200, reason ? { seq, woke: false, reason } : { seq });
      }
      if (kind === "push" && request.method === "PUT") {
        await this.relay.setPushToken(key, JSON.parse(body));
        return json(200, { ok: true });
      }
      if (kind === "messages" && request.method === "GET") {
        return json(200, await this.relay.since(key, url.searchParams.get("after")));
      }
      return json(405, { error: "method not allowed" });
    } catch (e) {
      if (e instanceof RelayError) return json(e.status, { error: e.message });
      if (e instanceof SyntaxError) return json(400, { error: "bad JSON" });
      throw e;
    }
  }

  /// Pushes to `targets`, forgets tokens APNs says are dead, and says whether any push got through.
  async wake(targets, kind, sealed) {
    const results = await Promise.all(targets.map((t) => push(this.env, t, kind, { sealed })));
    const dead = targets.filter((_, i) => results[i] === 410).map((t) => t.token);
    if (dead.length) await this.relay.dropPushTokens(dead);
    return results.some((s) => s >= 200 && s < 300);
  }

  /// Sends the pushes that did not fit in their call's request, then deletes expired messages.
  async alarm() {
    for (const batch of await this.relay.takePushes(SUBREQUESTS)) {
      if (batch.targets.length) await this.wake(batch.targets, batch.kind, batch.sealed);
    }
    const next = (await this.relay.pushesQueued()) ? Date.now() : await this.relay.sweep();
    if (next !== null) await this.state.storage.setAlarm(next);
  }
}

export class Meter {
  constructor(state) {
    this.meter = new MeterLogic(state.storage);
  }

  async fetch() {
    await this.meter.add(1);
    return json(200, await this.meter.status());
  }
}

function json(status, value) {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}
