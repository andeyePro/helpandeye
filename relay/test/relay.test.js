import assert from "node:assert/strict";
import { test } from "node:test";
import { b64, GroupRelay, KEEP_MS, MAX_SKEW_MS, Meter, RelayError, signingInput, WARN_FRACTION, FREE_DAILY_REQUESTS } from "../src/relay.js";

// Behaves like Durable Object storage for the calls the relay makes.
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
    async sign(method, path, body, timestamp) {
      const sig = await crypto.subtle.sign({ name: "Ed25519" }, pair.privateKey, await signingInput(method, path, String(timestamp), body));
      return { method, path, key, timestamp: String(timestamp), signature: b64(sig), body };
    },
  };
}

const rejects = (p, status) => assert.rejects(p, (e) => e instanceof RelayError && e.status === status);

test("a signed request authenticates; tampering, replay and stale clocks do not", async () => {
  let now = 1_793_000_000_000;
  const relay = new GroupRelay(new MapStorage(), () => now);
  const a = await phone();
  const req = await a.sign("POST", "/g/abc/messages", '{"sealed":"AA=="}', now);
  assert.equal(await relay.authenticate(req), a.key);
  await rejects(relay.authenticate({ ...req, body: '{"sealed":"AB=="}' }), 401);
  await rejects(relay.authenticate({ ...req, path: "/g/other/messages" }), 401);
  await rejects(relay.authenticate({ ...req, key: (await phone()).key }), 401);
  now += MAX_SKEW_MS + 1;
  await rejects(relay.authenticate(req), 401);
});

test("only members can post and read, and a removed phone is refused at once", async () => {
  const relay = new GroupRelay(new MapStorage());
  const coord = await phone(), member = await phone(), stranger = await phone();
  await rejects(relay.post(coord.key, "AA=="), 403);
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }, { key: member.key, role: "member" }] });
  assert.equal(await relay.post(member.key, "AAEC"), 1);
  assert.equal(await relay.post(coord.key, "AwQF"), 2);
  await rejects(relay.post(stranger.key, "AA=="), 403);
  await rejects(relay.since(stranger.key, 0), 403);
  assert.deepEqual((await relay.since(member.key, 1)).messages.map((m) => m.sealed), ["AwQF"]);
  assert.equal((await relay.since(member.key, 1)).latest, 2);
  await relay.setMembers(coord.key, { generation: 2, members: [{ key: coord.key, role: "coordinator" }] });
  await rejects(relay.since(member.key, 0), 403);
});

test("only a coordinator changes the member list, never backwards, and cannot remove themselves", async () => {
  const relay = new GroupRelay(new MapStorage());
  const coord = await phone(), member = await phone();
  const list = { generation: 2, members: [{ key: coord.key, role: "coordinator" }, { key: member.key, role: "member" }] };
  await relay.setMembers(coord.key, list);
  await rejects(relay.setMembers(member.key, { ...list, generation: 3 }), 403);
  await rejects(relay.setMembers(coord.key, { ...list, generation: 1 }), 409);
  await relay.setMembers(coord.key, { ...list, members: [...list.members].reverse() });
  await rejects(relay.setMembers(coord.key, { generation: 2, members: [{ key: coord.key, role: "coordinator" }] }), 409);
  await rejects(relay.setMembers(coord.key, { generation: 3, members: [{ key: member.key, role: "coordinator" }] }), 409);
  await rejects(relay.setMembers(coord.key, { generation: 3, members: [{ key: 1, role: "x" }] }), 400);
});

test("messages are kept for a week at most and must be base64 of a sane size", async () => {
  let now = 0;
  const relay = new GroupRelay(new MapStorage(), () => now);
  const coord = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }] });
  await relay.post(coord.key, "AA==");
  now = KEEP_MS + 1;
  await relay.post(coord.key, "AQ==");
  assert.deepEqual((await relay.since(coord.key, 0)).messages.map((m) => m.seq), [2]);
  await rejects(relay.post(coord.key, "not base64!"), 400);
  await rejects(relay.post(coord.key, "A".repeat(600)), 400);
  await rejects(relay.post(coord.key, ""), 400);
});

test("the meter warns before the free daily allowance runs out, and resets each day", async () => {
  let now = Date.parse("2026-10-27T10:00:00Z");
  const meter = new Meter(new MapStorage(), () => now);
  await meter.add(FREE_DAILY_REQUESTS * WARN_FRACTION - 1);
  assert.equal((await meter.status()).low, false);
  await meter.add(1);
  assert.equal((await meter.status()).low, true);
  now = Date.parse("2026-10-28T00:00:01Z");
  assert.equal((await meter.status()).used, 0);
  assert.equal(await meter.add(1), 1);
});

test("each message is its own key and old ones are deleted", async () => {
  let now = 0;
  const storage = new MapStorage();
  const relay = new GroupRelay(storage, () => now);
  const coord = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }] });
  for (let i = 0; i < 3; i++) await relay.post(coord.key, "AA==");
  assert.equal([...storage.m.keys()].filter((k) => k.startsWith("m:")).length, 3);
  now = KEEP_MS + 1;
  await relay.post(coord.key, "AQ==");
  assert.deepEqual([...storage.m.keys()].filter((k) => k.startsWith("m:")), [GroupRelay.key(4)]);
});

test("push tokens belong to current members and the sender is not woken", async () => {
  const relay = new GroupRelay(new MapStorage());
  const coord = await phone(), member = await phone(), stranger = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }, { key: member.key, role: "member" }] });
  await relay.setPushToken(coord.key, { token: "A".repeat(64), sandbox: true });
  await relay.setPushToken(member.key, { token: "b".repeat(64) });
  await rejects(relay.setPushToken(stranger.key, { token: "c".repeat(64) }), 403);
  await rejects(relay.setPushToken(member.key, { token: "not hex" }), 400);
  assert.deepEqual(await relay.pushTargets(coord.key), [{ token: "b".repeat(64), sandbox: false }]);
  await relay.setMembers(coord.key, { generation: 2, members: [{ key: coord.key, role: "coordinator" }] });
  assert.deepEqual(await relay.pushTargets(coord.key), []);
  assert.deepEqual(await relay.pushTargets(member.key), [{ token: "a".repeat(64), sandbox: true }]);
});

test("a first read can ask for the last few messages, and the cursor moves past expired ones", async () => {
  let now = 0;
  const relay = new GroupRelay(new MapStorage(), () => now);
  const coord = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }] });
  for (let i = 0; i < 5; i++) await relay.post(coord.key, "AA==");
  assert.deepEqual((await relay.since(coord.key, -2)).messages.map((m) => m.seq), [4, 5]);
  now = KEEP_MS + 1;
  const page = await relay.since(coord.key, 0);
  assert.deepEqual(page.messages, []);
  assert.equal(page.next, 5, "past the expired ones");
});

test("posts and pushes are limited per phone per minute, and old push tokens are deleted", async () => {
  let now = 0;
  const storage = new MapStorage();
  const relay = new GroupRelay(storage, () => now);
  const coord = await phone(), member = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }, { key: member.key, role: "member" }] });
  assert.equal(await relay.limit(member.key, true), true);
  assert.equal(await relay.limit(member.key, true), true);
  assert.equal(await relay.limit(member.key, true), false, "a third push in a minute is not sent");
  for (let i = 3; i < 20; i++) await relay.limit(member.key, false);
  await rejects(relay.limit(member.key, false), 429);
  now = 60_000;
  assert.equal(await relay.limit(member.key, true), true, "a new minute");
  await relay.setPushToken(member.key, { token: "b".repeat(64) });
  await relay.setMembers(coord.key, { generation: 2, members: [{ key: coord.key, role: "coordinator" }] });
  assert.equal(storage.m.has("p:" + member.key), false);
});

test("a merged list at the same version is accepted if it keeps everyone", async () => {
  const relay = new GroupRelay(new MapStorage());
  const coord = await phone(), a = await phone(), b = await phone();
  const base = [{ key: coord.key, role: "coordinator" }];
  await relay.setMembers(coord.key, { generation: 3, members: [...base, { key: a.key, role: "member" }] });
  await relay.setMembers(coord.key, { generation: 3, members: [...base, { key: a.key, role: "member" }, { key: b.key, role: "member" }] });
  assert.equal((await relay.members()).members.length, 3);
  await rejects(relay.setMembers(coord.key, { generation: 3, members: [...base, { key: b.key, role: "member" }] }), 409);
});

test("only the first coordinator takes people off, and nobody taken off comes back", async () => {
  const relay = new GroupRelay(new MapStorage());
  const owner = await phone(), second = await phone(), x = await phone(), y = await phone();
  const c = (k) => ({ key: k.key, role: "coordinator" }), m = (k) => ({ key: k.key, role: "member" });
  await relay.setMembers(owner.key, { generation: 1, members: [c(owner), c(second), m(x)] });
  await rejects(relay.setMembers(second.key, { generation: 2, members: [c(owner), c(second)] }), 403);
  await relay.setMembers(owner.key, { generation: 2, members: [c(owner), c(second)] });
  // The second coordinator, out of touch, adds y to a list that still has x.
  await rejects(relay.setMembers(second.key, { generation: 2, members: [c(owner), c(second), m(x), m(y)] }), 409);
  await relay.setMembers(second.key, { generation: 2, members: [c(owner), c(second), m(y)] });
  await rejects(relay.setMembers(second.key, { generation: 3, members: [c(second), m(y)] }), 403);
  await rejects(relay.setMembers(owner.key, { generation: 3, members: [c(owner), c(owner)] }), 400);
  await rejects(relay.since(x.key, 0), 403);
});
