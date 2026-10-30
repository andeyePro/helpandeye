import assert from "node:assert/strict";
import { test } from "node:test";
import { BUCKET_MS, DAY_MS, EVERYONE, Ledger, WINDOW_MS } from "../src/ledger.js";
import { cost, PRICES } from "../src/prices.js";
import { MapStorage } from "./storage.js";

const HOUR = 60 * 60 * 1000;

function ledger(start = 1_793_000_000_000) {
  const clock = { now: start };
  const storage = new MapStorage();
  return { clock, storage, ledger: new Ledger(storage, () => clock.now) };
}

test("two free answers a day for an address, counted from the first", async () => {
  const { clock, ledger: l } = ledger();
  assert.deepEqual(await l.take("a", 2), { allowed: true, remaining: 1 });
  assert.deepEqual(await l.take("a", 2), { allowed: true, remaining: 0 });
  assert.deepEqual(await l.take("a", 2), { allowed: false, remaining: 0 });
  assert.equal(await l.remaining("a", 2), 0);
  // Another address is counted on its own.
  assert.deepEqual(await l.take("b", 2), { allowed: true, remaining: 1 });
  clock.now += DAY_MS - 1;
  assert.deepEqual(await l.take("a", 2), { allowed: false, remaining: 0 });
  clock.now += 1;
  assert.equal(await l.remaining("a", 2), 2);
  assert.deepEqual(await l.take("a", 2), { allowed: true, remaining: 1 });
});

test("an answer that was never given is handed back", async () => {
  const { ledger: l } = ledger();
  await l.take("a", 2);
  await l.take("a", 2);
  await l.giveBack("a");
  assert.equal(await l.remaining("a", 2), 1);
  assert.deepEqual(await l.take("a", 2), { allowed: true, remaining: 0 });
  // Nothing to give back is not an error.
  await l.giveBack("nobody");
  assert.equal(await l.remaining("nobody", 2), 2);
});

test("spend is summed over a rolling six hours, for the user and for everyone", async () => {
  const { clock, ledger: l } = ledger();
  const t = { everyone: 100, user: 100 };
  await l.spend("u1", 1, t);
  clock.now += 2 * HOUR;
  await l.spend("u1", 2, t);
  await l.spend("u2", 5, t);
  assert.equal(await l.total("u1"), 3);
  assert.equal(await l.total("u2"), 5);
  assert.equal(await l.total(EVERYONE), 8);
  // Six hours and a bucket after the first dollar, it has dropped out of the window.
  clock.now = clock.now - 2 * HOUR + WINDOW_MS + BUCKET_MS;
  assert.equal(await l.total("u1"), 2);
  assert.equal(await l.total(EVERYONE), 7);
});

test("alerts: everyone over 2%, one user over 1%, each at most once in six hours", async () => {
  const { clock, ledger: l } = ledger();
  // A $200 month: everyone at $4, one user at $2.
  const t = { everyone: 4, user: 2 };
  assert.deepEqual(await l.spend("u1", 1.5, t), []);
  assert.deepEqual(await l.spend("u1", 0.5, t), [{ who: "u1", usd: 2, threshold: 2 }]);
  // The user is still over, but has been reported; everyone is not yet.
  assert.deepEqual(await l.spend("u1", 1, t), []);
  assert.deepEqual(await l.spend("u2", 1, t), [{ who: EVERYONE, usd: 4, threshold: 4 }]);
  // A different user crossing their own line is its own alert.
  assert.deepEqual(await l.spend("u2", 1, t), [{ who: "u2", usd: 2, threshold: 2 }]);
  clock.now += WINDOW_MS - 1;
  assert.deepEqual(await l.spend("u1", 0.1, t), []);
  // Six hours and a bucket on, the old spend has left the window, so a fresh crossing is
  // reported again.
  clock.now += BUCKET_MS + 1;
  assert.deepEqual(await l.spend("u1", 4, t), [{ who: EVERYONE, usd: 4.1, threshold: 4 }, { who: "u1", usd: 4.1, threshold: 2 }]);
});

test("the sweep forgets hashes after a day and spend after the window, and says when to come back", async () => {
  const { clock, storage, ledger: l } = ledger();
  const start = clock.now, bucket = Math.floor(start / BUCKET_MS) * BUCKET_MS;
  await l.take("a", 2);
  await l.spend("u1", 1, { everyone: 100, user: 100 });
  assert.equal(await l.sweep(), bucket + WINDOW_MS + BUCKET_MS);
  assert.equal(storage.m.size, 3);
  clock.now = bucket + WINDOW_MS + BUCKET_MS;
  assert.equal(await l.sweep(), start + DAY_MS);
  assert.deepEqual([...storage.m.keys()], ["free:a"]);
  clock.now = start + DAY_MS;
  assert.equal(await l.sweep(), null);
  assert.equal(storage.m.size, 0);
});

test("an alert record is swept once its six hours are up", async () => {
  const { clock, storage, ledger: l } = ledger();
  await l.spend("u1", 3, { everyone: 100, user: 2 });
  assert.ok(storage.m.has("alerted:u1"));
  clock.now += WINDOW_MS;
  await l.sweep();
  assert.ok(!storage.m.has("alerted:u1"));
});

test("cost is tokens at the model's list price, cache reads and writes included", () => {
  const usage = { input_tokens: 1_000_000, output_tokens: 100_000, cache_read_input_tokens: 500_000, cache_creation_input_tokens: 100_000 };
  const h = PRICES["claude-haiku-5-5"];
  assert.equal(cost("claude-haiku-5-5", usage).toFixed(9), (h.input + 0.1 * h.output + 0.5 * h.cacheRead + 0.1 * h.input * 1.25).toFixed(9));
  // A model not priced here is costed at the dearest price, and missing counts as zero.
  assert.equal(cost("claude-unknown", { input_tokens: 1_000_000, cache_read_input_tokens: null }), PRICES["claude-opus-5-5"].input);
});
