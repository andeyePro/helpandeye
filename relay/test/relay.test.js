import assert from "node:assert/strict";
import { test } from "node:test";
import { authenticate, b64, GroupRelay, isKey, verify, KEEP_MS, MAX_SKEW_MS, Meter, ownsGroup, RelayError, signingInput, WARN_FRACTION, FREE_DAILY_REQUESTS, RESEND_WINDOW_MS, TAKEOVER_SILENCE_MS } from "../src/relay.js";
import { MapStorage } from "./storage.js";

async function phone() {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const key = b64(await crypto.subtle.exportKey("raw", pair.publicKey));
  return {
    key,
    async sign(method, path, body, timestamp, raw = null) {
      const sig = await crypto.subtle.sign({ name: "Ed25519" }, pair.privateKey, raw ?? await signingInput(method, path, String(timestamp), body));
      return { method, path, key, timestamp: String(timestamp), signature: b64(sig), body };
    },
  };
}

const b64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const rejects = (p, status) => assert.rejects(p, (e) => e instanceof RelayError && e.status === status);

test("a signed request authenticates; tampering, replay and stale clocks do not", async () => {
  const now = 1_793_000_000_000;
  const a = await phone();
  const req = await a.sign("POST", "/g/abc/messages", '{"sealed":"AA=="}', now);
  assert.equal(await authenticate(req, now), a.key);
  await rejects(authenticate({ ...req, body: '{"sealed":"AB=="}' }, now), 401);
  await rejects(authenticate({ ...req, path: "/g/other/messages" }, now), 401);
  await rejects(authenticate({ ...req, key: (await phone()).key }, now), 401);
  await rejects(authenticate(req, now + MAX_SKEW_MS + 1), 401);
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
  assert.deepEqual(await relay.pushTargets(coord.key), [{ id: "p:" + member.key, token: "b".repeat(64), sandbox: false }]);
  await relay.setMembers(coord.key, { generation: 2, members: [{ key: coord.key, role: "coordinator" }], removed: [member.key] });
  assert.deepEqual(await relay.pushTargets(coord.key), []);
  assert.deepEqual(await relay.pushTargets(member.key), [{ id: "p:" + coord.key, token: "a".repeat(64), sandbox: true }]);
});

test("a member's watch has its own push token beside the phone's, and goes with the member", async () => {
  const relay = new GroupRelay(new MapStorage());
  const coord = await phone(), member = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }, { key: member.key, role: "member" }], primary: coord.key });
  await relay.setPushToken(member.key, { token: "b".repeat(64) });
  await relay.setPushToken(member.key, { token: "d".repeat(64), device: "watch" });
  assert.deepEqual(await relay.pushTargets(coord.key), [{ id: "p:" + member.key, token: "b".repeat(64), sandbox: false }, { id: "w:" + member.key, token: "d".repeat(64), sandbox: false, device: "watch" }]);
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

test("expired messages are deleted without anyone posting, and the next expiry is known", async () => {
  let now = 0;
  const storage = new MapStorage();
  const relay = new GroupRelay(storage, () => now);
  const coord = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }], primary: coord.key });
  for (let i = 0; i < 300; i++) await relay.post(coord.key, "AA==");
  now = 1000;
  await relay.post(coord.key, "AQ==");
  now = KEEP_MS + 1;
  assert.equal(await relay.sweep(), 1000 + KEEP_MS, "when the one left expires");
  assert.deepEqual([...storage.m.keys()].filter((k) => k.startsWith("m:")), [GroupRelay.key(301)]);
  now = KEEP_MS + 1001;
  assert.equal(await relay.sweep(), null);
  assert.equal([...storage.m.keys()].some((k) => k.startsWith("m:")), false);
});

test("a removed member's rate and wake records go with them", async () => {
  const storage = new MapStorage();
  const relay = new GroupRelay(storage);
  const coord = await phone(), member = await phone();
  await relay.setMembers(coord.key, { generation: 1, members: [{ key: coord.key, role: "coordinator" }, { key: member.key, role: "member" }], primary: coord.key });
  await relay.limit(member.key, false);
  await relay.limit(coord.key, false);
  await relay.markReached(member.key, "call", ["p:" + coord.key]);
  await relay.setMembers(coord.key, { generation: 2, members: [{ key: coord.key, role: "coordinator" }], removed: [member.key] });
  assert.equal(storage.m.has("r:" + member.key), false);
  assert.equal(storage.m.has("k:" + member.key), false);
  assert.equal(storage.m.has("r:" + coord.key), true);
});

test("who a wake reached is kept per sender and kind, for a resend's window only", async () => {
  let now = 0;
  const relay = new GroupRelay(new MapStorage(), () => now);
  const a = await phone(), b = await phone();
  await relay.markReached(a.key, "call", ["p:x"]);
  now = RESEND_WINDOW_MS - 1;
  await relay.markReached(a.key, "call", ["w:x"]);
  assert.deepEqual([...(await relay.reached(a.key, "call"))], ["p:x", "w:x"]);
  assert.equal((await relay.reached(a.key, "quiet")).size, 0, "a quiet wake is not a call's");
  assert.equal((await relay.reached(b.key, "call")).size, 0, "nor another phone's");
  now = RESEND_WINDOW_MS;
  assert.equal((await relay.reached(a.key, "call")).size, 0, "counted from the first push, a later call wakes everyone again");
});

test("a member list is stored in one write, and removing many members deletes in batches", async () => {
  const storage = new MapStorage();
  const relay = new GroupRelay(storage);
  const coord = await phone();
  const others = await Promise.all(Array.from({ length: 150 }, phone));
  const list = (g, members, removed = []) => ({ generation: g, members: [{ key: coord.key, role: "coordinator" }, ...members.map((p) => ({ key: p.key, role: "member" }))], removed: removed.map((p) => p.key), primary: coord.key });
  await relay.setMembers(coord.key, list(1, others));
  for (const p of others) {
    await relay.setPushToken(p.key, { token: "b".repeat(64) });
    await relay.setPushToken(p.key, { token: "c".repeat(64), device: "watch" });
    await relay.limit(p.key, false);
  }
  const puts = storage.puts;
  await relay.setMembers(coord.key, list(2, [], others));
  assert.equal(storage.puts - puts, 1, "one put");
  assert.equal([...storage.m.keys()].filter((k) => /^[pwr]:/.test(k)).length, 0, "450 keys deleted, at most 128 at a time");
});

// Decision 20: a coordinator takes over the group from the first coordinator's lost phone. The
// group keeps its ID; the relay checks the takeover as the phones do and takes the new owner.
async function takeoverSetUp() {
  const relay = new GroupRelay(new MapStorage(), () => takeoverSetUp.now);
  const owner = await phone(), second = await phone(), third = await phone(), member = await phone();
  const c = (k) => ({ key: k.key, role: "coordinator" }), m = (k) => ({ key: k.key, role: "member" });
  const nonce = crypto.getRandomValues(new Uint8Array(8));
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array([...new TextEncoder().encode("HELPA-GROUP-1"), ...nonce, ...Uint8Array.from(atob(owner.key), (ch) => ch.charCodeAt(0))])));
  const id = new Uint8Array([...nonce, ...hash.slice(0, 8)]);
  await relay.setMembers(owner.key, { generation: 1, members: [c(owner), c(second), c(third), m(member)], primary: owner.key }, id);
  const raw = (k) => Uint8Array.from(atob(k), (ch) => ch.charCodeAt(0));
  const input = new Uint8Array([...new TextEncoder().encode("HELPA-TAKEOVER-1"), ...id, ...raw(owner.key), ...raw(second.key)]);
  const sign = async (p) => ({ key: p.key, signature: (await p.sign("", "", "", 0, input)).signature });
  const list = (by, extra = {}) => ({ generation: 2, members: [c(second), c(third), m(member)], removed: [owner.key], primary: second.key,
    takeover: { from: owner.key, to: second.key, signatures: [], ...extra } });
  return { relay, owner, second, third, member, id, input, raw, sign, list, c, m };
}
takeoverSetUp.now = 1_793_000_000_000;

test("a takeover needs the new first coordinator's signature and proof; alone it waits seven days", async () => {
  const { relay, owner, second, third, member, id, sign, list } = await takeoverSetUp();
  const mine = await sign(second);
  // Nothing without the new first coordinator's own signature, or with a member's or the owner's.
  await rejects(relay.setMembers(second.key, list(second, { signatures: [await sign(third)] }), id), 403);
  await rejects(relay.setMembers(second.key, list(second, { signatures: [mine, await sign(member)] }), id), 403);
  await rejects(relay.setMembers(second.key, list(second, { signatures: [mine, await sign(owner)] }), id), 403);
  await rejects(relay.setMembers(second.key, list(second, { signatures: [mine, mine] }), id), 403);
  await rejects(relay.setMembers(second.key, list(second, { signatures: [] }), id), 400);
  await rejects(relay.setMembers(second.key, list(second, { signatures: [mine], from: third.key }), id), 403);
  // Alone and within seven days of the owner's last request: not yet. Only the new owner's own
  // list brings a takeover; another coordinator's waits too.
  await rejects(relay.setMembers(second.key, list(second, { signatures: [mine] }), id), 425);
  await rejects(relay.setMembers(third.key, list(second, { signatures: [mine] }), id), 425);
  // The lost phone must be among the removed.
  takeoverSetUp.now += TAKEOVER_SILENCE_MS;
  await rejects(relay.setMembers(second.key, { ...list(second, { signatures: [mine] }), removed: [] }, id), 400);
  assert.equal((await relay.members()).members.some((e) => e.key === owner.key), true, "nothing changed");
  // Seven days on, the single signature is enough.
  await relay.setMembers(second.key, list(second, { signatures: [mine] }), id);
  assert.equal(await relay.storage.get("owner"), second.key);
  assert.equal((await relay.members()).members.some((e) => e.key === owner.key), false, "the lost phone is out");
  await rejects(relay.since(owner.key, 0), 403);
  // The new owner removes people and sets roles; the old owner's list is refused.
  await relay.setMembers(second.key, { generation: 3, members: [{ key: second.key, role: "coordinator" }, { key: third.key, role: "coordinator" }], removed: [owner.key, member.key], primary: second.key }, id);
  assert.deepEqual((await relay.members()).members.map((e) => e.key).sort(), [second.key, third.key].sort());
  await rejects(relay.setMembers(owner.key, { generation: 9, members: [{ key: owner.key, role: "coordinator" }], primary: owner.key }, id), 403);
  // Later lists carrying the same record change nothing, from the new owner or anyone else.
  await relay.setMembers(third.key, { generation: 4, members: [{ key: second.key, role: "coordinator" }, { key: third.key, role: "coordinator" }], primary: second.key,
    takeover: { from: owner.key, to: second.key, signatures: [mine] } }, id);
  assert.equal(await relay.storage.get("owner"), second.key);
});

test("the owner's request resets the seven days, and two coordinators or the named deputy need no wait", async () => {
  const { relay, owner, second, third, id, raw, sign, list } = await takeoverSetUp();
  const mine = await sign(second);
  takeoverSetUp.now += TAKEOVER_SILENCE_MS - 1000;
  await relay.heard(owner.key);
  takeoverSetUp.now += 2000;
  await rejects(relay.setMembers(second.key, list(second, { signatures: [mine] }), id), 425, "heard from within seven days");
  await relay.heard(third.key);
  // Two coordinators: at once.
  const agreed = new GroupRelay(new MapStorage());
  await relay.setMembers(second.key, list(second, { signatures: [mine, await sign(third)] }), id);
  assert.equal(await relay.storage.get("owner"), second.key);
  // The deputy the owner named, signed over the deputy's key and the naming's version: at once.
  const fresh = await takeoverSetUp();
  const version = 3;
  const named = new Uint8Array([...new TextEncoder().encode("HELPA-DEPUTY-1"), ...fresh.id, ...fresh.raw(fresh.second.key), version, 0, 0, 0]);
  const naming = (await fresh.owner.sign("", "", "", 0, named)).signature;
  const theirs = await fresh.sign(fresh.second);
  await rejects(fresh.relay.setMembers(fresh.second.key, fresh.list(fresh.second, { signatures: [theirs], deputy: { version: 4, signature: naming } }), fresh.id), 425, "another version is another naming");
  await rejects(fresh.relay.setMembers(fresh.second.key, fresh.list(fresh.second, { signatures: [await fresh.sign(fresh.third)], deputy: { version, signature: naming } }), fresh.id), 403);
  await fresh.relay.setMembers(fresh.second.key, fresh.list(fresh.second, { signatures: [theirs], deputy: { version, signature: naming } }), fresh.id);
  assert.equal(await fresh.relay.storage.get("owner"), fresh.second.key);
  // A naming the owner has since replaced, as their list told the relay, proves nothing.
  const replaced = await takeoverSetUp();
  const old = new Uint8Array([...new TextEncoder().encode("HELPA-DEPUTY-1"), ...replaced.id, ...replaced.raw(replaced.second.key), 1, 0, 0, 0]);
  await replaced.relay.setMembers(replaced.owner.key, { generation: 2, members: [replaced.c(replaced.owner), replaced.c(replaced.second), replaced.c(replaced.third)], primary: replaced.owner.key, deputyVersion: 2 }, replaced.id);
  await rejects(replaced.relay.setMembers(replaced.second.key, { ...replaced.list(replaced.second, { signatures: [await replaced.sign(replaced.second)], deputy: { version: 1, signature: (await replaced.owner.sign("", "", "", 0, old)).signature } }), generation: 3 }, replaced.id), 425);
  await rejects(replaced.relay.setMembers(replaced.owner.key, { generation: 3, members: [replaced.c(replaced.owner)], primary: replaced.owner.key, deputyVersion: -1 }, replaced.id), 400);
  // With no group ID there is nothing to check the signatures against.
  await agreed.setMembers(owner.key, { generation: 1, members: [{ key: owner.key, role: "coordinator" }, { key: second.key, role: "coordinator" }], primary: owner.key });
  await rejects(agreed.setMembers(second.key, list(second, { signatures: [mine, await sign(third)] })), 400);
});

test("a group registered before the relay kept watch starts its seven days at the first takeover", async () => {
  const { relay, second, id, sign, list } = await takeoverSetUp();
  await relay.storage.delete("ownerSeenAt");
  const mine = await sign(second);
  await rejects(relay.setMembers(second.key, list(second, { signatures: [mine] }), id), 425);
  takeoverSetUp.now += TAKEOVER_SILENCE_MS - 1000;
  await rejects(relay.setMembers(second.key, list(second, { signatures: [mine] }), id), 425, "not seven days since the relay began to watch");
  takeoverSetUp.now += 1000;
  await relay.setMembers(second.key, list(second, { signatures: [mine] }), id);
  assert.equal(await relay.storage.get("owner"), second.key);
});

test("a new first coordinator's deputy counts afresh, whatever the lost phone's namings reached", async () => {
  const { relay, owner, second, third, member, id, raw, sign, list, c, m } = await takeoverSetUp();
  // The lost phone had named deputies up to version 5.
  await relay.setMembers(owner.key, { generation: 2, members: [c(owner), c(second), c(third), m(member)], primary: owner.key, deputyVersion: 5 }, id);
  takeoverSetUp.now += TAKEOVER_SILENCE_MS;
  await relay.setMembers(second.key, { ...list(second, { signatures: [await sign(second)] }), generation: 3 }, id);
  assert.equal(await relay.storage.get("owner"), second.key);
  assert.equal(await relay.storage.get("deputyVersion"), 0, "the old owner's namings count for nothing now");
  // The new owner names the third coordinator, their first naming, and loses their phone at once.
  await relay.setMembers(second.key, { generation: 4, members: [c(second), c(third), m(member)], removed: [owner.key], primary: second.key, deputyVersion: 1,
    takeover: { from: owner.key, to: second.key, signatures: [await sign(second)] } }, id);
  assert.equal(await relay.storage.get("deputyVersion"), 1);
  const named = new Uint8Array([...new TextEncoder().encode("HELPA-DEPUTY-1"), ...id, ...raw(third.key), 1, 0, 0, 0]);
  const input = new Uint8Array([...new TextEncoder().encode("HELPA-TAKEOVER-1"), ...id, ...raw(second.key), ...raw(third.key)]);
  const theirs = { key: third.key, signature: (await third.sign("", "", "", 0, input)).signature };
  await relay.setMembers(third.key, { generation: 5, members: [c(third), m(member)], removed: [owner.key, second.key], primary: third.key,
    takeover: { from: second.key, to: third.key, signatures: [theirs], deputy: { version: 1, signature: (await second.sign("", "", "", 0, named)).signature } } }, id);
  assert.equal(await relay.storage.get("owner"), third.key, "the deputy takes over at once");
});
