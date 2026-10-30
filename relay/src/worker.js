import { configured, push } from "./apns.js";
import { checkPass, PASS_HEADER, requiresPass } from "./pass.js";
import { authenticate, GroupRelay, KEEP_MS, MAX_MEMBERS_REQUEST, MAX_REQUEST, Meter as MeterLogic, RelayError, unb64 } from "./relay.js";

// Routes:
//   PUT  /g/<groupId>/members          coordinator sends the member list (public keys only)
//   POST /g/<groupId>/messages         a member posts a sealed message
//   GET  /g/<groupId>/messages?after=n a member fetches sealed messages after sequence n
//   PUT  /g/<groupId>/push             a member registers its push token
// A message may carry "wake": "call" (a visible push to the others) or "quiet" (wakes their app).
// Every request carries X-HelpA-Key, X-HelpA-Time and X-HelpA-Signature, checked here before any
// group sees the request, and, when the relay requires one (REQUIRE_PASS), the group's pass in
// X-HelpA-Pass, checked the same way.
// Every response carries X-HelpA-Allowance-Low: 1 when the free daily allowance is nearly used.

const GROUP_ID = /^[A-Za-z0-9_-]{16,64}$/;
// Workers on the free plan may make 50 subrequests per invocation, and each push is one. One is
// kept back for the meter, which a group's alarm asks.
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
      const limit = m[2] === "members" ? MAX_MEMBERS_REQUEST : MAX_REQUEST;
      if (Number(request.headers.get("Content-Length")) > limit) throw new RelayError(413, "too large");
      const body = await readBody(request, limit);
      const key = request.headers.get("X-HelpA-Key") ?? "";
      try {
        await authenticate({
          method: request.method,
          path: url.pathname + url.search,
          key,
          timestamp: request.headers.get("X-HelpA-Time") ?? "",
          signature: request.headers.get("X-HelpA-Signature") ?? "",
          body,
        });
      } catch (e) {
        // Only failures are counted by address, so phones sharing one (a care home's Wi-Fi, a
        // carrier's shared IPv4) never hold each other back.
        if (!(await allowed(env.IP_LIMIT, request.headers.get("CF-Connecting-IP") ?? ""))) throw new RelayError(429, "too many requests");
        throw e;
      }
      // With REQUIRE_PASS set, the group must hold Help&I's pass for this relay (pass.js). Checked
      // here, with nothing stored, so a group without one costs no Durable Object request.
      if (requiresPass(env)) {
        if (!env.ISSUER_KEY) throw new RelayError(500, "issuer key not set");
        await checkPass(request.headers.get(PASS_HEADER), m[1], env.ISSUER_KEY);
      }
      // A post that wakes others for a call is held back only by its group's limits for each phone.
      let call = false;
      try { call = m[2] === "messages" && request.method === "POST" && JSON.parse(body)?.wake === "call"; } catch {}
      if (!call && !(await allowed(env.KEY_LIMIT, key))) throw new RelayError(429, "too many requests");
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
      if (kind === "members" && request.method === "PUT") {
        const list = JSON.parse(body);
        const registering = !(await this.relay.members());
        const id = groupId.replace(/-/g, "+").replace(/_/g, "/");
        await this.relay.setMembers(key, list, unb64(id + "=".repeat((4 - (id.length % 4)) % 4)));
        // A new group keeps state for whoever registers it, so each address may register only a
        // few. Counted once it is registered, so a refused list uses up nothing.
        if (registering && !(await allowed(this.env.REGISTER_LIMIT, request.headers.get("CF-Connecting-IP") ?? ""))) {
          await this.state.storage.deleteAll();
          throw new RelayError(429, "too many new groups");
        }
        return json(200, { ok: true });
      }
      if (kind === "messages" && request.method === "POST") {
        const msg = JSON.parse(body);
        if (!msg || typeof msg !== "object") throw new RelayError(400, "bad message");
        const wakes = msg.wake === "call" || msg.wake === "quiet";
        const mayWake = await this.relay.limit(key, wakes);
        const seq = await this.relay.post(key, msg.sealed);
        if ((await this.state.storage.getAlarm()) === null) await this.state.storage.setAlarm(Date.now() + KEEP_MS);
        // Told when nobody was woken, so the client asks again on its resend. A call has woken
        // someone only once a phone took its push: a watch's push is quiet.
        let reason;
        if (wakes && !mayWake) reason = "too many wakes";
        else if (wakes && configured(this.env)) {
          const counts = (id) => msg.wake !== "call" || id.startsWith("p:");
          // A resend goes to those the earlier sends have not reached, and not to those still queued.
          const reached = await this.relay.reached(key, msg.wake), queued = await this.relay.queued(key, msg.wake);
          const targets = (await this.relay.pushTargets(key)).filter((t) => !reached.has(t.id) && !queued.has(t.id));
          const later = targets.slice(PUSH_BATCH).map((t) => t.id);
          if (later.length) {
            await this.relay.queuePushes(seq, { sender: key, kind: msg.wake, sealed: msg.sealed, targets: later });
            await this.state.storage.setAlarm(Date.now());
          }
          const woken = await this.wake(key, msg.wake, msg.sealed, targets.slice(0, PUSH_BATCH));
          const pending = [...queued, ...later];
          if (![...reached, ...pending, ...targets.map((t) => t.id)].some(counts)) reason = "no phone to wake";
          else if (![...reached, ...pending, ...woken].some(counts)) reason = "no push got through";
        }
        return json(200, reason ? { seq, woke: false, reason } : { seq });
      }
      if (kind === "push" && request.method === "PUT") {
        await this.relay.setPushToken(key, JSON.parse(body));
        return json(200, { ok: true });
      }
      if (kind === "messages" && request.method === "GET") {
        // Counted for members only, so someone outside the group cannot use up its limit.
        if ((await this.relay.isMember(key)) && !(await allowed(this.env.GROUP_LIMIT, groupId))) throw new RelayError(429, "too many requests for this group");
        return json(200, await this.relay.since(key, url.searchParams.get("after")));
      }
      return json(405, { error: "method not allowed" });
    } catch (e) {
      if (e instanceof RelayError) return json(e.status, { error: e.message });
      if (e instanceof SyntaxError) return json(400, { error: "bad JSON" });
      throw e;
    }
  }

  /// Pushes `sender`'s wake to `targets`, forgets tokens APNs says are dead, and notes and returns
  /// the ids of those whose push got through.
  async wake(sender, kind, sealed, targets) {
    const results = await Promise.all(targets.map((t) => push(this.env, t, kind, { sealed })));
    const dead = targets.filter((_, i) => results[i] === 410).map((t) => t.token);
    if (dead.length) await this.relay.dropPushTokens(dead);
    const woken = targets.filter((_, i) => results[i] >= 200 && results[i] < 300).map((t) => t.id);
    await this.relay.markReached(sender, kind, woken);
    return woken;
  }

  /// Sends the pushes that did not fit in their call's request, then deletes expired messages.
  /// Each run is a Durable Object request, so it is counted by the meter as a relay request is.
  async alarm() {
    for (const batch of await this.relay.takePushes(PUSH_BATCH)) {
      if (batch.targets.length) await this.wake(batch.sender, batch.kind, batch.sealed, batch.targets);
    }
    const next = (await this.relay.pushesQueued()) ? Date.now() : await this.relay.sweep();
    if (next !== null) await this.state.storage.setAlarm(next);
    await count(this.env);
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
