import { GroupRelay, Meter as MeterLogic, RelayError } from "./relay.js";

// Routes:
//   PUT  /g/<groupId>/members          coordinator sends the member list (public keys only)
//   POST /g/<groupId>/messages         a member posts a sealed message
//   GET  /g/<groupId>/messages?after=n a member fetches sealed messages after sequence n
// Every request carries X-HelpAndI-Key, X-HelpAndI-Time and X-HelpAndI-Signature.
// Every response carries X-HelpAndI-Allowance-Low: 1 when the free daily allowance is nearly used.

const GROUP_ID = /^[A-Za-z0-9_-]{16,64}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const m = url.pathname.match(/^\/g\/([^/]+)\/(members|messages)$/);
    if (!m || !GROUP_ID.test(m[1])) return json(404, { error: "not found" });
    const stub = env.GROUPS.get(env.GROUPS.idFromName(m[1]));
    const response = await stub.fetch(request);
    const meter = env.METER.get(env.METER.idFromName("all"));
    const low = await (await meter.fetch("https://meter/add", { method: "POST" })).json();
    const out = new Response(response.body, response);
    if (low.low) out.headers.set("X-HelpAndI-Allowance-Low", "1");
    return out;
  },
};

export class Group {
  constructor(state) {
    this.relay = new GroupRelay(state.storage);
  }

  async fetch(request) {
    try {
      const url = new URL(request.url);
      const body = request.method === "GET" ? "" : await request.text();
      if (body.length > 64 * 1024) throw new RelayError(413, "too large");
      const key = await this.relay.authenticate({
        method: request.method,
        path: url.pathname + url.search,
        key: request.headers.get("X-HelpAndI-Key") ?? "",
        timestamp: request.headers.get("X-HelpAndI-Time") ?? "",
        signature: request.headers.get("X-HelpAndI-Signature") ?? "",
        body,
      });
      const kind = url.pathname.split("/").pop();
      if (kind === "members" && request.method === "PUT") {
        await this.relay.setMembers(key, JSON.parse(body));
        return json(200, { ok: true });
      }
      if (kind === "messages" && request.method === "POST") {
        return json(200, { seq: await this.relay.post(key, JSON.parse(body).sealed) });
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
