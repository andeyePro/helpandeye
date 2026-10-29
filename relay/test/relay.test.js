import assert from "node:assert/strict";
import { test } from "node:test";
import { b64, GroupRelay, isKey, verify, KEEP_MS, MAX_SKEW_MS, Meter, ownsGroup, RelayError, signingInput, WARN_FRACTION, FREE_DAILY_REQUESTS } from "../src/relay.js";

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

const b64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
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
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }, { key: member.key, role: "member" }], primary: coord.key });
  assert.equal(await relay.post(member.key, "AAEC"), 1);
  assert.equal(await relay.post(coord.key, "AwQF"), 2);
  await rejects(relay.post(stranger.key, "AA=="), 403);
  await rejects(relay.since(stranger.key, 0), 403);
  assert.deepEqual((await relay.since(member.key, 1)).messages.map((m) => m.sealed), ["AwQF"]);
  assert.equal((await relay.since(member.key, 1)).latest, 2);
  await relay.setMembers(coord.key, { generation: 2, members: [{ key: coord.key, role: "coordinator" }], removed: [member.key] });
  await rejects(relay.since(member.key, 0), 403);
});


test("messages are kept for a week at most and must be base64 of a sane size", async () => {
  let now = 0;
  const relay = new GroupRelay(new MapStorage(), () => now);
  const coord = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }], primary: coord.key });
  await relay.post(coord.key, "AA==");
  now = KEEP_MS + 1;
  await relay.post(coord.key, "AQ==");
  assert.deepEqual((await relay.since(coord.key, 0)).messages.map((m) => m.seq), [2]);
  await rejects(relay.post(coord.key, "not base64!"), 400);
  await relay.post(coord.key, "A".repeat(3000));
  await rejects(relay.post(coord.key, "A".repeat(5000)), 400);
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
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }], primary: coord.key });
  for (let i = 0; i < 3; i++) await relay.post(coord.key, "AA==");
  assert.equal([...storage.m.keys()].filter((k) => k.startsWith("m:")).length, 3);
  now = KEEP_MS + 1;
  await relay.post(coord.key, "AQ==");
  assert.deepEqual([...storage.m.keys()].filter((k) => k.startsWith("m:")), [GroupRelay.key(4)]);
});

test("push tokens belong to current members and the sender is not woken", async () => {
  const relay = new GroupRelay(new MapStorage());
  const coord = await phone(), member = await phone(), stranger = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }, { key: member.key, role: "member" }], primary: coord.key });
  await relay.setPushToken(coord.key, { token: "A".repeat(64), sandbox: true });
  await relay.setPushToken(member.key, { token: "b".repeat(64) });
  await rejects(relay.setPushToken(stranger.key, { token: "c".repeat(64) }), 403);
  await rejects(relay.setPushToken(member.key, { token: "not hex" }), 400);
  assert.deepEqual(await relay.pushTargets(coord.key), [{ token: "b".repeat(64), sandbox: false }]);
  await relay.setMembers(coord.key, { generation: 2, members: [{ key: coord.key, role: "coordinator" }], removed: [member.key] });
  assert.deepEqual(await relay.pushTargets(coord.key), []);
  assert.deepEqual(await relay.pushTargets(member.key), [{ token: "a".repeat(64), sandbox: true }]);
});

test("a member's watch has its own push token beside the phone's, and goes with the member", async () => {
  const relay = new GroupRelay(new MapStorage());
  const coord = await phone(), member = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }, { key: member.key, role: "member" }], primary: coord.key });
  await relay.setPushToken(member.key, { token: "b".repeat(64) });
  await relay.setPushToken(member.key, { token: "d".repeat(64), device: "watch" });
  assert.deepEqual(await relay.pushTargets(coord.key), [{ token: "b".repeat(64), sandbox: false }, { token: "d".repeat(64), sandbox: false, device: "watch" }]);
  assert.deepEqual(await relay.pushTargets(member.key), [], "a member's own watch is not woken by its own call");
  await relay.setMembers(coord.key, { generation: 2, members: [{ key: coord.key, role: "coordinator" }], removed: [member.key] });
  assert.deepEqual(await relay.pushTargets(coord.key), []);
});

test("a first read can ask for the last few messages, and the cursor moves past expired ones", async () => {
  let now = 0;
  const relay = new GroupRelay(new MapStorage(), () => now);
  const coord = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }], primary: coord.key });
  for (let i = 0; i < 5; i++) await relay.post(coord.key, "AA==");
  assert.deepEqual((await relay.since(coord.key, -2)).messages.map((m) => m.seq), [4, 5]);
  now = KEEP_MS + 1;
  const page = await relay.since(coord.key, 0);
  assert.deepEqual(page.messages, []);
  assert.equal(page.next, 5, "past the expired ones");
});

test("a signed stranger leaves no rate record", async () => {
  const storage = new MapStorage();
  const relay = new GroupRelay(storage);
  const coord = await phone(), stranger = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }], primary: coord.key });
  await rejects(relay.limit(stranger.key, true), 403);
  assert.equal(storage.m.has("r:" + stranger.key), false);
});

test("posts and pushes are limited per phone per minute, and old push tokens are deleted", async () => {
  let now = 0;
  const storage = new MapStorage();
  const relay = new GroupRelay(storage, () => now);
  const coord = await phone(), member = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }, { key: member.key, role: "member" }], primary: coord.key });
  assert.equal(await relay.limit(member.key, true), true);
  assert.equal(await relay.limit(member.key, true), true);
  assert.equal(await relay.limit(member.key, true), false, "a third push in a minute is not sent");
  for (let i = 3; i < 20; i++) await relay.limit(member.key, false);
  await rejects(relay.limit(member.key, false), 429);
  now = 60_000;
  assert.equal(await relay.limit(member.key, true), true, "a new minute");
  await relay.setPushToken(member.key, { token: "b".repeat(64) });
  await relay.setMembers(coord.key, { generation: 2, members: [{ key: coord.key, role: "coordinator" }], removed: [member.key] });
  assert.equal(storage.m.has("p:" + member.key), false);
});



test("lists add people; only the owner's named removals take anyone off, for good", async () => {
  const relay = new GroupRelay(new MapStorage());
  const owner = await phone(), second = await phone(), x = await phone(), y = await phone(), stranger = await phone();
  const c = (k) => ({ key: k.key, role: "coordinator" }), m = (k) => ({ key: k.key, role: "member" });
  const keys = async () => (await relay.members()).members.map((e) => e.key).sort();
  await relay.setMembers(owner.key, { generation: 1, members: [c(owner), c(second), m(x)], primary: owner.key });
  // The second coordinator adds y; the owner, not yet told, sends a list without y: y stays.
  await relay.setMembers(second.key, { generation: 2, members: [c(owner), c(second), m(x), m(y)] });
  await relay.setMembers(owner.key, { generation: 2, members: [c(owner), c(second), m(x)] });
  assert.deepEqual(await keys(), [owner.key, second.key, x.key, y.key].sort());
  // Only the owner's named removal takes x off, and x can never come back.
  await rejects(relay.setMembers(second.key, { generation: 3, members: [c(owner), c(second), m(y)], removed: [x.key] }), 403);
  assert.equal((await keys()).includes(x.key), true, "a removal named by someone else does nothing");
  await relay.setMembers(owner.key, { generation: 3, members: [c(owner), c(second), m(y)], removed: [x.key] });
  await relay.setMembers(second.key, { generation: 4, members: [c(owner), c(second), m(x), m(y)] });
  assert.equal((await keys()).includes(x.key), false, "a removed key listed again stays off");
  await rejects(relay.since(x.key, 0), 403);
  // Only the owner sets roles; nobody else can make someone a coordinator.
  await relay.setMembers(second.key, { generation: 5, members: [c(owner), c(second), c(y)] });
  assert.equal((await relay.members()).members.find((e) => e.key === y.key).role, "member");
  await rejects(relay.setMembers(stranger.key, { generation: 9, members: [c(stranger)] }), 403);
  await rejects(relay.setMembers(owner.key, { generation: 6, members: [c(owner)], removed: [owner.key] }), 409);
  await rejects(relay.setMembers(owner.key, { generation: 6, members: [c(owner), c(owner)] }), 400);
});

test("only the first coordinator, whose key the group ID is made from, can register a group", async () => {
  const owner = await phone(), second = await phone(), member = await phone();
  const c = (k) => ({ key: k.key, role: "coordinator" }), m = (k) => ({ key: k.key, role: "member" });
  const nonce = crypto.getRandomValues(new Uint8Array(8));
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array([...new TextEncoder().encode("HELPA-GROUP-1"), ...nonce, ...Uint8Array.from(atob(owner.key), (ch) => ch.charCodeAt(0))])));
  const id = new Uint8Array([...nonce, ...hash.slice(0, 8)]);
  assert.equal(await ownsGroup(id, owner.key), true);
  assert.equal(await ownsGroup(id, member.key), false);
  // A member who knows the ID cannot register it naming themselves.
  await rejects(new GroupRelay(new MapStorage()).setMembers(member.key, { generation: 1, members: [c(member)], primary: member.key }, id), 403);
  // Nor can someone who lists themselves as a coordinator beside the real first one, with or without the ID.
  const first = new GroupRelay(new MapStorage());
  // Turned away for now, not for good: once the first coordinator registers, the same list is taken.
  await rejects(first.setMembers(second.key, { generation: 1, members: [c(owner), c(second)], primary: owner.key }, id), 425);
  await rejects(first.setMembers(second.key, { generation: 1, members: [c(owner), c(second)], primary: owner.key }), 425);
  assert.equal(await first.members(), null);
  await first.setMembers(owner.key, { generation: 1, members: [c(owner), c(second)], primary: owner.key }, id);
  await first.setMembers(second.key, { generation: 1, members: [c(owner), c(second)], primary: owner.key }, id);
  const relay = new GroupRelay(new MapStorage());
  await relay.setMembers(owner.key, { generation: 1, members: [c(owner), c(second), c(member)], primary: owner.key }, id);
  await rejects(relay.setMembers(second.key, { generation: 2, members: [c(owner), c(second)], primary: second.key }, id), 409);
});

test("removing a coordinator takes off people only they added, and owner roles never go backwards", async () => {
  const relay = new GroupRelay(new MapStorage());
  const owner = await phone(), second = await phone(), y = await phone(), z = await phone();
  const c = (k) => ({ key: k.key, role: "coordinator" }), m = (k) => ({ key: k.key, role: "member" });
  const keys = async () => (await relay.members()).members.map((e) => e.key);
  await relay.setMembers(owner.key, { generation: 1, members: [c(owner), c(second)], primary: owner.key });
  await relay.setMembers(second.key, { generation: 2, members: [c(owner), c(second), m(y), m(z)] });
  // The owner has heard of z but not y, and removes the second coordinator.
  await relay.setMembers(owner.key, { generation: 3, members: [c(owner), m(z)], removed: [second.key] });
  assert.deepEqual((await keys()).sort(), [owner.key, z.key].sort());
  await relay.setMembers(owner.key, { generation: 5, members: [c(owner), m(z)] });
  await relay.setMembers(owner.key, { generation: 4, members: [c(owner), c(z)] });
  assert.equal((await relay.members()).members.find((e) => e.key === z.key).role, "member", "a delayed older list does not promote");
});

test("people a removed coordinator alone added stay off a stale list; only the owner brings them back", async () => {
  const relay = new GroupRelay(new MapStorage());
  const owner = await phone(), second = await phone(), third = await phone(), y = await phone();
  const c = (k) => ({ key: k.key, role: "coordinator" }), m = (k) => ({ key: k.key, role: "member" });
  const has = async (k) => (await relay.members()).members.some((e) => e.key === k.key);
  await relay.setMembers(owner.key, { generation: 1, members: [c(owner), c(second), c(third)], primary: owner.key });
  await relay.setMembers(second.key, { generation: 2, members: [c(owner), c(second), c(third), m(y)] });
  await relay.setMembers(owner.key, { generation: 3, members: [c(owner), c(third)], removed: [second.key] });
  assert.equal(await has(y), false, "went with the coordinator who added them");
  await relay.setMembers(third.key, { generation: 4, members: [c(owner), c(third), m(y)] });
  assert.equal(await has(y), false, "another coordinator's stale list does not bring them back");
  await relay.setMembers(owner.key, { generation: 5, members: [c(owner), c(third), m(y)] });
  assert.equal(await has(y), true, "the owner can");
  await relay.setMembers(owner.key, { generation: 6, members: [c(owner), c(third)], removed: [y.key] });
  await relay.setMembers(owner.key, { generation: 7, members: [c(owner), c(third), m(y)] });
  assert.equal(await has(y), false, "an explicit removal is still for good");
});

test("malformed lists and base64 are refused with 400, not thrown", async () => {
  const relay = new GroupRelay(new MapStorage());
  const owner = await phone();
  const c = (k) => ({ key: k.key, role: "coordinator" });
  await rejects(relay.setMembers(owner.key, { generation: 1, members: [c(owner), null], primary: owner.key }), 400);
  await rejects(relay.setMembers(owner.key, { generation: 1, members: [c(owner), 7], primary: owner.key }), 400);
  await rejects(relay.setMembers(owner.key, { generation: 1, members: [c(owner)], removed: [null], primary: owner.key }), 400);
  await rejects(relay.setMembers(owner.key, "x"), 400);
  await relay.setMembers(owner.key, { generation: 1, members: [c(owner)], primary: owner.key });
  await rejects(relay.post(owner.key, "A"), 400);
  assert.equal(await verify(owner.key, "A", new Uint8Array(1)), false);
});

test("a public key has one spelling: aliases that differ only in unused bits are refused", async () => {
  const owner = await phone();
  assert.equal(isKey(owner.key), true);
  const alias = owner.key.slice(0, 42) + b64Alphabet[b64Alphabet.indexOf(owner.key[42]) ^ 1] + "=";
  assert.notEqual(alias, owner.key);
  assert.equal(b64(Uint8Array.from(atob(alias), (ch) => ch.charCodeAt(0))), owner.key, "decodes to the same bytes");
  assert.equal(isKey(alias), false);
  await rejects(new GroupRelay(new MapStorage()).setMembers(owner.key, { generation: 1, members: [{ key: alias, role: "coordinator" }], primary: alias }), 400);
});

test("keys must be keys, and the list has a size limit", async () => {
  const relay = new GroupRelay(new MapStorage());
  const owner = await phone();
  const c = (k) => ({ key: k.key, role: "coordinator" });
  await rejects(relay.setMembers(owner.key, { generation: 1, members: [c(owner), { key: "junk", role: "member" }], primary: owner.key }), 400);
  const many = Array.from({ length: 256 }, (_, i) => ({ key: btoa(String.fromCharCode(...new Uint8Array(32).fill(i % 256).map((b, j) => (b + j * 7) % 256))), role: "member" }));
  await rejects(relay.setMembers(owner.key, { generation: 1, members: [c(owner), ...many], primary: owner.key }), 413);
});

test("the log has a name that changes only if the relay's storage is reset", async () => {
  const coord = await phone();
  const relay = new GroupRelay(new MapStorage());
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }], primary: coord.key });
  const a = (await relay.since(coord.key, 0)).epoch;
  await relay.post(coord.key, "AA==");
  assert.equal((await relay.since(coord.key, 0)).epoch, a);
  const reset = new GroupRelay(new MapStorage());
  await reset.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }], primary: coord.key });
  assert.notEqual((await reset.since(coord.key, 0)).epoch, a);
});
