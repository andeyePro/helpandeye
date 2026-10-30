import assert from "node:assert/strict";
import { test } from "node:test";
import relay, { Group, Meter, PUSH_BATCH } from "../src/worker.js";
import { b64, KEEP_MS, MAX_MEMBERS_REQUEST, MAX_REQUEST, MAX_REMOVED, MAX_MEMBERS, MAX_SKEW_MS, MAX_WAKES_PER_MINUTE, signingInput } from "../src/relay.js";
import { MapStorage } from "./storage.js";

async function phone() {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const key = b64(await crypto.subtle.exportKey("raw", pair.publicKey));
  return {
    key,
    async request(method, path, body, { time = Date.now(), headers = {} } = {}) {
      const t = String(time);
      const sig = await crypto.subtle.sign({ name: "Ed25519" }, pair.privateKey, await signingInput(method, path, t, body));
      return new Request("https://relay" + path, { method, body: method === "GET" ? undefined : body, headers: { "X-HelpA-Key": key, "X-HelpA-Time": t, "X-HelpA-Signature": b64(sig), ...headers } });
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

// A group ID made from `owner`'s key, as the app makes it.
async function groupId(owner) {
  const nonce = crypto.getRandomValues(new Uint8Array(8));
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array([...new TextEncoder().encode("HELPA-GROUP-1"), ...nonce, ...Uint8Array.from(atob(owner.key), (ch) => ch.charCodeAt(0))])));
  return b64(new Uint8Array([...nonce, ...hash.slice(0, 8)])).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const firstList = (owner, ...members) => JSON.stringify({ generation: 1, primary: owner.key, members: [{ key: owner.key, role: "coordinator" }, ...members.map((m) => ({ key: m.key, role: "member" }))] });

async function setup(env = {}) {
  const owner = await phone(), member = await phone();
  const id = await groupId(owner);
  const storage = new MapStorage();
  const group = new Group({ storage }, env);
  const path = (kind) => `/g/${id}/${kind}`;
  assert.equal((await group.fetch(await owner.request("PUT", path("members"), firstList(owner, member)))).status, 200);
  return { owner, member, group, storage, path };
}

// The Worker in front of its Durable Objects, counting what reaches them.
function worker(extra = {}) {
  const groups = new Map(), reached = { groups: 0, meter: 0 }, pending = [];
  const meter = new Meter({ storage: new MapStorage() });
  const env = {
    GROUPS: {
      idFromName: (name) => name,
      get: (id) => ({
        async fetch(url, init) {
          reached.groups += 1;
          if (!groups.has(id)) groups.set(id, new Group({ storage: new MapStorage() }, env));
          return groups.get(id).fetch(new Request(url, init));
        },
      }),
    },
    METER: { idFromName: (name) => name, get: () => ({ fetch: async () => { reached.meter += 1; return meter.fetch(); } }) },
    ...extra,
  };
  const ctx = { waitUntil: (p) => pending.push(p) };
  return { env, reached, fetch: (request) => relay.fetch(request, env, ctx), settle: () => Promise.all(pending.splice(0)) };
}

// A rate limiting binding that refuses the keys in `refused`, and notes every key it is asked about.
function limiter(refused = new Set()) {
  const asked = [];
  return { asked, refused, limit: async ({ key }) => { asked.push(key); return { success: !refused.has(key) }; } };
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

test("unsigned, badly signed and stale requests are turned away before any group or the meter", async () => {
  const w = worker();
  const owner = await phone();
  const path = `/g/${await groupId(owner)}/members`;
  const body = firstList(owner);
  assert.equal((await w.fetch(new Request("https://relay" + path, { method: "PUT", body }))).status, 401);
  const signed = await owner.request("PUT", path, body);
  assert.equal((await w.fetch(new Request(signed.url, { method: "PUT", headers: signed.headers, body: body + " " }))).status, 401);
  assert.equal((await w.fetch(await owner.request("PUT", path, body, { time: Date.now() - MAX_SKEW_MS - 1000 }))).status, 401);
  await w.settle();
  assert.deepEqual(w.reached, { groups: 0, meter: 0 });
  assert.equal((await w.fetch(await owner.request("PUT", path, body))).status, 200);
  await w.settle();
  assert.deepEqual(w.reached, { groups: 1, meter: 1 }, "an authenticated request is counted");
});

test("a body over the limit is refused before it is read, whatever Content-Length says", async () => {
  const w = worker();
  const owner = await phone();
  const id = await groupId(owner);
  const unread = (kind, length) => ({
    method: "PUT",
    url: `https://relay/g/${id}/${kind}`,
    headers: new Headers({ "Content-Length": String(length) }),
    get body() { throw new Error("the body was read"); },
  });
  assert.equal((await w.fetch(unread("members", MAX_MEMBERS_REQUEST + 1))).status, 413);
  assert.equal((await w.fetch(unread("push", MAX_REQUEST + 1))).status, 413);
  const chunk = new Uint8Array(1024);
  let sent = 0;
  const endless = new ReadableStream({ pull(c) { sent += 1; c.enqueue(chunk); } });
  const chunked = new Request(`https://relay/g/${id}/messages`, { method: "POST", body: endless, duplex: "half" });
  assert.equal((await w.fetch(chunked)).status, 413);
  assert.ok(sent <= MAX_REQUEST / 1024 + 2, "stopped reading at the limit");
  assert.equal(w.reached.groups, 0);
});

test("the largest member list the app can send fits the limit and is taken", async () => {
  const w = worker();
  const owner = await phone();
  // Keys mostly of "/", which Swift's JSONEncoder sends as "\/": the longest a key can be.
  const key = (i) => b64(new Uint8Array(32).fill(0xff).fill(i & 0xff, 0, 1).fill(i >> 8, 1, 2));
  const members = [{ key: owner.key, role: "coordinator" }, ...Array.from({ length: MAX_MEMBERS - 1 }, (_, i) => ({ key: key(i), role: "coordinator" }))];
  const removed = Array.from({ length: MAX_REMOVED }, (_, i) => key(i + 1000));
  const body = JSON.stringify({ generation: 4_000_000_000, members, removed, primary: owner.key }).replaceAll("/", "\\/");
  assert.ok(body.length > 64 * 1024 && body.length < MAX_MEMBERS_REQUEST, `${body.length} bytes`);
  assert.equal((await w.fetch(await owner.request("PUT", `/g/${await groupId(owner)}/members`, body))).status, 200);
});

test("a failing or slow meter neither fails nor holds up a reply, and its last answer is used", { timeout: 5000 }, async () => {
  const owner = await phone();
  const path = `/g/${await groupId(owner)}/members`;
  let answer;
  const w = worker({ METER: { idFromName: (n) => n, get: () => ({ fetch: () => answer() }) } });
  answer = async () => { throw new Error("meter down"); };
  assert.equal((await w.fetch(await owner.request("PUT", path, firstList(owner)))).status, 200);
  await w.settle();
  answer = () => new Promise(() => {});
  const slow = await w.fetch(await owner.request("GET", path.replace("members", "messages"), ""));
  assert.equal(slow.status, 200, "answered while the meter never replies");
  w.settle();
  answer = async () => Response.json({ low: true });
  assert.equal((await w.fetch(await owner.request("GET", path.replace("members", "messages"), ""))).headers.get("X-HelpA-Allowance-Low"), null);
  await w.settle();
  assert.equal((await w.fetch(await owner.request("GET", path.replace("members", "messages"), ""))).headers.get("X-HelpA-Allowance-Low"), "1", "from the last answer");
  answer = async () => Response.json({ low: false });
  await w.fetch(await owner.request("GET", path.replace("members", "messages"), ""));
  await w.settle();
});

test("requests are limited per address before any group is reached", async () => {
  const ip = limiter(new Set(["203.0.113.9"]));
  const w = worker({ IP_LIMIT: ip });
  const owner = await phone();
  const path = `/g/${await groupId(owner)}/members`;
  assert.equal((await w.fetch(await owner.request("PUT", path, firstList(owner), { headers: { "CF-Connecting-IP": "203.0.113.9" } }))).status, 429);
  assert.equal(w.reached.groups, 0);
  assert.equal((await w.fetch(await owner.request("PUT", path, firstList(owner), { headers: { "CF-Connecting-IP": "203.0.113.10" } }))).status, 200);
  assert.deepEqual(ip.asked, ["203.0.113.9", "203.0.113.10"]);
});

test("a group's limit counts its members only, so outsiders cannot use it up", async () => {
  const groupLimit = limiter();
  const { member, group, path } = await setup({ GROUP_LIMIT: groupLimit });
  const id = path("").split("/")[2];
  const stranger = await phone();
  const asked = groupLimit.asked.length;
  assert.equal((await group.fetch(await stranger.request("GET", path("messages"), ""))).status, 403);
  assert.equal(groupLimit.asked.length, asked, "a stranger is not counted");
  assert.equal((await group.fetch(await member.request("GET", path("messages"), ""))).status, 200);
  groupLimit.refused.add(id);
  assert.equal((await group.fetch(await member.request("GET", path("messages"), ""))).status, 429);
});

test("each address may register only a few new groups", async () => {
  const register = limiter(new Set(["203.0.113.9"]));
  const w = worker({ REGISTER_LIMIT: register });
  const owner = await phone(), second = await phone();
  const path = `/g/${await groupId(owner)}/members`;
  const from = (ip) => ({ headers: { "CF-Connecting-IP": ip } });
  assert.equal((await w.fetch(await second.request("PUT", path, firstList(owner, second), from("203.0.113.9")))).status, 425, "not a registration");
  assert.equal((await w.fetch(await owner.request("PUT", path, firstList(owner), from("203.0.113.9")))).status, 429);
  assert.equal((await w.fetch(await owner.request("PUT", path, firstList(owner), from("203.0.113.10")))).status, 200);
  assert.equal((await w.fetch(await owner.request("PUT", path, firstList(owner, second), from("203.0.113.9")))).status, 200, "a change to a group is not");
  assert.deepEqual(register.asked, ["203.0.113.9", "203.0.113.10"]);
});

test("the post says when no wake got through, and a resend wakes again", async (t) => {
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

test("any refusal from APNs, such as a bad provider token, means nobody was woken", async (t) => {
  const env = await apnsEnv();
  const { owner, member, group, path } = await setup(env);
  const third = await phone();
  await group.fetch(await owner.request("PUT", path("members"), JSON.stringify({ generation: 2, members: [{ key: owner.key, role: "coordinator" }, { key: member.key, role: "member" }, { key: third.key, role: "member" }] })));
  await group.fetch(await member.request("PUT", path("push"), JSON.stringify({ token: "b".repeat(64) })));
  await group.fetch(await third.request("PUT", path("push"), JSON.stringify({ token: "c".repeat(64) })));
  let answers;
  t.mock.method(globalThis, "fetch", async (url) => answers[url.endsWith("b".repeat(64)) ? 0 : 1]);
  const post = async (sender) => (await (await group.fetch(await sender.request("POST", path("messages"), '{"sealed":"AA==","wake":"call"}'))).json());
  answers = [{ status: 403, json: async () => ({ reason: "InvalidProviderToken" }) }, { status: 400, json: async () => ({ reason: "BadTopic" }) }];
  const reply = await post(owner);
  assert.equal(reply.woke, false);
  assert.equal(typeof reply.reason, "string");
  answers = [{ status: 200 }, answers[1]];
  assert.equal((await post(third)).woke, undefined, "one got through");
});

test("a dead token is dropped and not tried again, and nobody was woken by it", async (t) => {
  const env = await apnsEnv();
  const { owner, member, group, path } = await setup(env);
  await group.fetch(await member.request("PUT", path("push"), JSON.stringify({ token: "b".repeat(64) })));
  t.mock.method(globalThis, "fetch", async () => ({ status: 400, json: async () => ({ reason: "BadDeviceToken" }) }));
  const post = async () => (await (await group.fetch(await owner.request("POST", path("messages"), '{"sealed":"AA==","wake":"call"}'))).json());
  assert.equal((await post()).woke, false);
  await post();
  assert.equal(globalThis.fetch.mock.callCount(), 1);
});

test("pushes beyond one request's subrequests are sent by the group's alarm", async (t) => {
  const env = await apnsEnv();
  const { owner, group, storage, path } = await setup(env);
  const others = await Promise.all(Array.from({ length: PUSH_BATCH + 11 }, phone));
  await group.fetch(await owner.request("PUT", path("members"), JSON.stringify({ generation: 2, members: [{ key: owner.key, role: "coordinator" }, ...others.map((p) => ({ key: p.key, role: "member" }))] })));
  others.forEach((p, i) => storage.m.set("p:" + p.key, { token: i.toString(16).padStart(64, "0"), sandbox: false }));
  const pushed = new Set();
  t.mock.method(globalThis, "fetch", async (url) => { pushed.add(url.split("/").pop()); return { status: 200 }; });
  assert.deepEqual(await (await group.fetch(await owner.request("POST", path("messages"), '{"sealed":"AA==","wake":"call"}'))).json(), { seq: 1 });
  assert.equal(pushed.size, PUSH_BATCH);
  assert.ok(storage.alarm <= Date.now(), "the alarm is due now");
  await group.alarm();
  assert.equal(pushed.size, others.length, "every other phone woken");
  assert.equal(globalThis.fetch.mock.callCount(), others.length, "each once");
  assert.ok(storage.alarm > Date.now() + KEEP_MS - 60_000, "next, when the message expires");
});

test("the group's alarm deletes expired messages without anyone posting", async () => {
  const { owner, group, storage, path } = await setup();
  await group.fetch(await owner.request("POST", path("messages"), '{"sealed":"AA=="}'));
  assert.ok(storage.alarm > Date.now() + KEEP_MS - 60_000);
  const key = [...storage.m.keys()].find((k) => k.startsWith("m:"));
  storage.m.set(key, { ...storage.m.get(key), at: Date.now() - KEEP_MS - 1 });
  storage.alarm = null;
  await group.alarm();
  assert.equal(storage.m.has(key), false);
  assert.equal(storage.alarm, null, "nothing left to expire");
});
