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

test("only requests that fail the signature check are limited by address", async () => {
  const ip = limiter(new Set(["203.0.113.9"]));
  const w = worker({ IP_LIMIT: ip });
  const owner = await phone();
  const path = `/g/${await groupId(owner)}/members`;
  const from = (ip) => ({ headers: { "CF-Connecting-IP": ip } });
  const signed = await owner.request("PUT", path, firstList(owner), from("203.0.113.9"));
  const forged = (ip) => {
    const headers = new Headers(signed.headers);
    headers.set("CF-Connecting-IP", ip);
    return new Request(signed.url, { method: "PUT", headers, body: firstList(owner) + " " });
  };
  assert.equal((await w.fetch(forged("203.0.113.9"))).status, 429, "failures from a busy address");
  assert.equal((await w.fetch(forged("203.0.113.10"))).status, 401);
  assert.equal(w.reached.groups, 0);
  // A care home's phones share an address: one phone's bad requests never hold back another's.
  assert.equal((await w.fetch(signed)).status, 200);
  assert.deepEqual(ip.asked, ["203.0.113.9", "203.0.113.10"], "a signed request is not counted");
});

test("signed requests are limited per key, but never a post that wakes others for a call", async () => {
  const keys = limiter();
  const w = worker({ KEY_LIMIT: keys });
  const owner = await phone();
  const id = await groupId(owner);
  const path = (kind) => `/g/${id}/${kind}`;
  assert.equal((await w.fetch(await owner.request("PUT", path("members"), firstList(owner)))).status, 200);
  keys.refused.add(owner.key);
  assert.equal((await w.fetch(await owner.request("GET", path("messages"), ""))).status, 429);
  assert.equal((await w.fetch(await owner.request("POST", path("messages"), '{"sealed":"AA=="}'))).status, 429);
  assert.equal((await w.fetch(await owner.request("POST", path("messages"), '{"sealed":"AA==","wake":"call"}'))).status, 200);
  assert.deepEqual(keys.asked, [owner.key, owner.key, owner.key], "a call is not even counted");
});

test("a group's limit counts its members' reads only, and never holds back a post", async () => {
  const groupLimit = limiter();
  const { owner, member, group, path } = await setup({ GROUP_LIMIT: groupLimit });
  const id = path("").split("/")[2];
  const stranger = await phone();
  const asked = groupLimit.asked.length;
  assert.equal((await group.fetch(await stranger.request("GET", path("messages"), ""))).status, 403);
  assert.equal(groupLimit.asked.length, asked, "a stranger is not counted");
  assert.equal((await group.fetch(await member.request("GET", path("messages"), ""))).status, 200);
  groupLimit.refused.add(id);
  assert.equal((await group.fetch(await member.request("GET", path("messages"), ""))).status, 429);
  const before = groupLimit.asked.length;
  assert.equal((await group.fetch(await member.request("POST", path("messages"), '{"sealed":"AA==","wake":"call"}'))).status, 200, "a call goes through");
  assert.equal((await group.fetch(await owner.request("POST", path("messages"), '{"sealed":"AA=="}'))).status, 200);
  assert.equal((await group.fetch(await member.request("PUT", path("push"), JSON.stringify({ token: "b".repeat(64) })))).status, 200);
  assert.equal(groupLimit.asked.length, before, "only reads are counted");
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
  const refused = await phone();
  const refusedPath = `/g/${await groupId(refused)}/members`;
  assert.equal((await w.fetch(await refused.request("PUT", refusedPath, firstList(refused), from("203.0.113.9")))).status, 429);
  assert.equal((await w.fetch(await refused.request("GET", refusedPath.replace("members", "messages"), ""))).status, 403, "a refused registration leaves nothing behind");
});

test("a registration is counted against its address only once the list is taken", async () => {
  const register = limiter();
  const w = worker({ REGISTER_LIMIT: register });
  const owner = await phone(), other = await phone();
  const path = `/g/${await groupId(owner)}/members`;
  assert.equal((await w.fetch(await other.request("PUT", path, firstList(other), { headers: { "CF-Connecting-IP": "203.0.113.9" } }))).status, 403, "not this group's owner");
  assert.equal((await w.fetch(await owner.request("PUT", path, '{"generation":1,"members":[]}', { headers: { "CF-Connecting-IP": "203.0.113.9" } }))).status, 400);
  assert.deepEqual(register.asked, []);
  assert.equal((await w.fetch(await owner.request("PUT", path, firstList(owner), { headers: { "CF-Connecting-IP": "203.0.113.9" } }))).status, 200);
  assert.deepEqual(register.asked, ["203.0.113.9"]);
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
  assert.deepEqual(await post(), { seq: 2, woke: false, reason: "no phone to wake" }, "with no token left, still nobody woken");
  assert.equal(globalThis.fetch.mock.callCount(), 1);
});

test("a call wakes someone only when a phone takes its push, and a resend skips whoever was reached", async (t) => {
  const env = await apnsEnv();
  const { owner, member, group, path } = await setup(env);
  // Each in a new minute, as the app's resends are, so the limit on wakes is not reached.
  const post = async (wake) => {
    await group.state.storage.delete("r:" + owner.key);
    return (await (await group.fetch(await owner.request("POST", path("messages"), JSON.stringify({ sealed: "AA==", wake })))).json());
  };
  assert.deepEqual(await post("call"), { seq: 1, woke: false, reason: "no phone to wake" }, "nobody has registered");
  await group.fetch(await member.request("PUT", path("push"), JSON.stringify({ token: "d".repeat(64), device: "watch" })));
  t.mock.method(globalThis, "fetch", async (url) => ({ status: url.endsWith("b".repeat(64)) ? 503 : 200, json: async () => ({}) }));
  assert.equal((await post("call")).reason, "no phone to wake", "a watch alone is woken quietly");
  assert.equal((await post("quiet")).woke, undefined, "but a quiet wake has reached it");
  await group.fetch(await member.request("PUT", path("push"), JSON.stringify({ token: "b".repeat(64) })));
  const tried = () => globalThis.fetch.mock.calls.map((c) => c.arguments[0].split("/").pop());
  const before = tried().length;
  assert.equal((await post("call")).reason, "no push got through", "the watch took it, the phone did not");
  assert.deepEqual(tried().slice(before), ["b".repeat(64)], "the watch, reached by the call before, is not pushed again");
  t.mock.method(globalThis, "fetch", async () => ({ status: 200 }));
  assert.equal((await post("call")).woke, undefined);
  assert.equal(globalThis.fetch.mock.callCount(), 1, "only the phone not reached yet");
  assert.equal((await post("call")).woke, undefined, "reached already");
  assert.equal(globalThis.fetch.mock.callCount(), 1, "nobody pushed twice");
});

// A group with `n` members besides its owner, each with a phone token.
async function crowd(n, env) {
  const { owner, group, storage, path } = await setup(env);
  const others = await Promise.all(Array.from({ length: n }, phone));
  await group.fetch(await owner.request("PUT", path("members"), JSON.stringify({ generation: 2, members: [{ key: owner.key, role: "coordinator" }, ...others.map((p) => ({ key: p.key, role: "member" }))] })));
  others.forEach((p, i) => storage.m.set("p:" + p.key, { token: i.toString(16).padStart(64, "0"), sandbox: false }));
  const call = async (sender, sealed = "AA==") => (await (await group.fetch(await sender.request("POST", path("messages"), JSON.stringify({ sealed, wake: "call" })))).json());
  return { owner, others, group, storage, path, call };
}

test("pushes beyond one request's subrequests are sent by the group's alarm, queued by member", async (t) => {
  const env = await apnsEnv();
  const { others, group, storage, call, owner } = await crowd(PUSH_BATCH + 11, env);
  const pushed = new Set();
  t.mock.method(globalThis, "fetch", async (url) => { pushed.add(url.split("/").pop()); return { status: 200 }; });
  assert.deepEqual(await call(owner), { seq: 1 });
  assert.equal(pushed.size, PUSH_BATCH);
  const queued = [...storage.m].find(([k]) => k.startsWith("q:"))[1];
  assert.deepEqual(queued.targets, others.map((p) => "p:" + p.key).sort().slice(PUSH_BATCH), "member and device, not tokens");
  assert.ok(storage.alarm <= Date.now(), "the alarm is due now");
  await group.alarm();
  assert.equal(pushed.size, others.length, "every other phone woken");
  assert.equal(globalThis.fetch.mock.callCount(), others.length, "each once");
  assert.ok(storage.alarm > Date.now() + KEEP_MS - 60_000, "next, when the message expires");
});

test("while pushes are still queued, a failed first batch is not reported as nobody woken", async (t) => {
  const env = await apnsEnv();
  const { others, group, call, owner } = await crowd(PUSH_BATCH + 3, env);
  let status = 503;
  t.mock.method(globalThis, "fetch", async () => ({ status, json: async () => ({}) }));
  assert.deepEqual(await call(owner), { seq: 1 }, "the alarm still has phones to try");
  status = 200;
  await group.alarm();
  assert.equal(globalThis.fetch.mock.callCount(), others.length);
});

test("the alarm pushes to the tokens members have when it runs, and not to anyone removed", async (t) => {
  const env = await apnsEnv();
  const { others, group, storage, path, call, owner } = await crowd(PUSH_BATCH + 2, env);
  t.mock.method(globalThis, "fetch", async () => ({ status: 200 }));
  await call(owner);
  const [gone, moved] = [...storage.m].find(([k]) => k.startsWith("q:"))[1].targets.map((id) => others.find((p) => "p:" + p.key === id));
  await group.fetch(await owner.request("PUT", path("members"), JSON.stringify({ generation: 3, members: others.filter((p) => p !== gone).map((p) => ({ key: p.key, role: "member" })).concat({ key: owner.key, role: "coordinator" }), removed: [gone.key] })));
  await group.fetch(await moved.request("PUT", path("push"), JSON.stringify({ token: "e".repeat(64) })));
  const before = globalThis.fetch.mock.callCount();
  await group.alarm();
  assert.deepEqual(globalThis.fetch.mock.calls.slice(before).map((c) => c.arguments[0].split("/").pop()), ["e".repeat(64)], "the new token, and not the removed member");
});

test("several calls queued at once each reach everyone once", async (t) => {
  const env = await apnsEnv();
  const { others, group, storage, call, owner } = await crowd(PUSH_BATCH + 20, env);
  const pushes = new Map();
  t.mock.method(globalThis, "fetch", async (url, init) => {
    const k = JSON.parse(init.body).sealed + url.split("/").pop();
    pushes.set(k, (pushes.get(k) ?? 0) + 1);
    return { status: 200 };
  });
  // The push carries the sealed message, so each call is told apart by its own.
  const callers = [owner, others[0], others[1]];
  for (const [i, sender] of callers.entries()) assert.deepEqual(Object.keys(await call(sender, b64([i]))), ["seq"]);
  assert.equal([...storage.m.keys()].filter((k) => k.startsWith("q:")).length, 3);
  for (let runs = 0; await group.relay.pushesQueued(); runs++) {
    assert.ok(runs < 10);
    await group.alarm();
  }
  // The owner has no token, so the other two calls reach one phone fewer.
  assert.equal(pushes.size, others.length + 2 * (others.length - 1), "everyone but the caller, for each call");
  assert.ok([...pushes.values()].every((n) => n === 1), "and once only");
});

test("each run of the group's alarm is counted by the meter", async () => {
  let added = 0;
  const { group } = await setup({ METER: { idFromName: (n) => n, get: () => ({ fetch: async () => { added += 1; return Response.json({ low: false }); } }) } });
  await group.alarm();
  assert.equal(added, 1);
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
