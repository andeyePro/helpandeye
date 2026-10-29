import assert from "node:assert/strict";
import { test } from "node:test";
import { Group } from "../src/worker.js";
import { b64, MAX_WAKES_PER_MINUTE, signingInput } from "../src/relay.js";

class MapStorage {
  constructor() { this.m = new Map(); }
  async get(k) { return structuredClone(this.m.get(k)); }
  async put(k, v) { this.m.set(k, structuredClone(v)); }
  async delete(keys) { for (const k of [].concat(keys)) this.m.delete(k); }
  async list({ prefix = "", start = "", limit = Infinity } = {}) {
    const keys = [...this.m.keys()].filter((k) => k.startsWith(prefix) && k >= start).sort().slice(0, limit);
    return new Map(keys.map((k) => [k, structuredClone(this.m.get(k))]));
  }
}

async function phone() {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const key = b64(await crypto.subtle.exportKey("raw", pair.publicKey));
  return {
    key,
    async request(method, path, body) {
      const t = String(Date.now());
      const sig = await crypto.subtle.sign({ name: "Ed25519" }, pair.privateKey, await signingInput(method, path, t, body));
      return new Request("https://relay" + path, { method, body: method === "GET" ? undefined : body, headers: { "X-HelpA-Key": key, "X-HelpA-Time": t, "X-HelpA-Signature": b64(sig) } });
    },
  };
}

// A real APNs key is not needed: the fake fetch below answers for Apple.
async function apnsEnv() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const label = ["PRIVATE", "KEY"].join(" ");
  return { APNS_KEY: `-----BEGIN ${label}-----\n${btoa(String.fromCharCode(...der))}\n-----END ${label}-----\n`, APNS_KEY_ID: "ABC123DEFG", APNS_TEAM_ID: "TEAM123456", APNS_TOPIC: "com.andeye.help" };
}

// A group whose id is made from `owner`'s key, as the app makes it.
async function setup(env = {}) {
  const owner = await phone(), member = await phone();
  const nonce = crypto.getRandomValues(new Uint8Array(8));
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array([...new TextEncoder().encode("HELPA-GROUP-1"), ...nonce, ...Uint8Array.from(atob(owner.key), (ch) => ch.charCodeAt(0))])));
  const id = b64(new Uint8Array([...nonce, ...hash.slice(0, 8)])).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const storage = new MapStorage();
  const group = new Group({ storage, waitUntil() {} }, env);
  const path = (kind) => `/g/${id}/${kind}`;
  const list = JSON.stringify({ generation: 1, primary: owner.key, members: [{ key: owner.key, role: "coordinator" }, { key: member.key, role: "member" }] });
  assert.equal((await group.fetch(await owner.request("PUT", path("members"), list))).status, 200);
  return { owner, member, group, storage, path };
}

test("malformed authenticated requests get a 400 from the worker, never an exception", async () => {
  const { owner, group, path } = await setup();
  const put = async (body) => (await group.fetch(await owner.request("PUT", path("members"), body))).status;
  assert.equal(await put('{"generation":2,"members":[null]}'), 400);
  assert.equal(await put('{"generation":2,"members":[{"key":"A","role":"member"}]}'), 400);
  assert.equal(await put("null"), 400);
  const post = async (body) => (await group.fetch(await owner.request("POST", path("messages"), body))).status;
  assert.equal(await post('{"sealed":"A"}'), 400);
  assert.equal(await post("null"), 400);
  assert.equal(await post("not json"), 400);
  assert.equal((await group.fetch(await owner.request("PUT", path("push"), "null"))).status, 400);
});

test("a stranger's signed post is refused without a rate record", async () => {
  const { group, storage, path } = await setup();
  const stranger = await phone();
  assert.equal((await group.fetch(await stranger.request("POST", path("messages"), '{"sealed":"AA=="}'))).status, 403);
  assert.equal([...storage.m.keys()].some((k) => k === "r:" + stranger.key), false);
});

test("the post says when no wake got through, drops dead tokens, and a resend wakes again", async (t) => {
  const env = await apnsEnv();
  const { owner, member, group, path } = await setup(env);
  await group.fetch(await member.request("PUT", path("push"), JSON.stringify({ token: "b".repeat(64) })));
  let status = 503, reason;
  t.mock.method(globalThis, "fetch", async () => ({ status, json: async () => ({ reason }) }));
  const post = async () => (await (await group.fetch(await owner.request("POST", path("messages"), '{"sealed":"AA==","wake":"call"}'))).json());
  assert.equal((await post()).woke, false, "a transient failure is reported");
  assert.equal(globalThis.fetch.mock.callCount(), 1);
  status = 200;
  assert.equal((await post()).woke, undefined, "success says nothing");
  assert.equal(globalThis.fetch.mock.callCount(), 2, "a resend wakes again");
  // Codex NR7: past the minute's wakes the message is kept but nobody is woken, and it says so,
  // so the phone asks for a wake again on its next resend.
  for (let i = 2; i < MAX_WAKES_PER_MINUTE; i++) await post();
  const calls = globalThis.fetch.mock.callCount();
  assert.equal((await post()).woke, false, "held back by the limit");
  assert.equal(globalThis.fetch.mock.callCount(), calls, "and Apple was not asked");
});

test("a token APNs says is dead is dropped and not tried again", async (t) => {
  const env = await apnsEnv();
  const { owner, member, group, path } = await setup(env);
  await group.fetch(await member.request("PUT", path("push"), JSON.stringify({ token: "b".repeat(64) })));
  t.mock.method(globalThis, "fetch", async () => ({ status: 400, json: async () => ({ reason: "BadDeviceToken" }) }));
  const post = async () => (await (await group.fetch(await owner.request("POST", path("messages"), '{"sealed":"AA==","wake":"call"}'))).json());
  assert.equal((await post()).woke, undefined, "a dead token is not worth a retry");
  await post();
  assert.equal(globalThis.fetch.mock.callCount(), 1);
});
