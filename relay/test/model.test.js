import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { GroupRelay, RelayError } from "../src/relay.js";

// The fuzz test of the app (app/HelpAndICore, EngineFuzzTests) uses a Swift copy of the relay's
// membership rules. These are the member-list publishes from some of its runs, with what that copy
// said; the real relay must say the same and end with the same list.
// Regenerate: HELPANDI_RELAY_LOG=<file> HELPANDI_FUZZ_SEEDS=4 swift test --filter EngineFuzzTests

class MapStorage {
  constructor() { this.m = new Map(); }
  async get(k) { return structuredClone(this.m.get(k)); }
  async put(k, v) { this.m.set(k, structuredClone(v)); }
  async delete(keys) { for (const k of [].concat(keys)) this.m.delete(k); }
  async list({ prefix = "" } = {}) {
    return new Map([...this.m.keys()].filter((k) => k.startsWith(prefix)).sort().map((k) => [k, this.m.get(k)]));
  }
}

const runs = readFileSync(new URL("./model-vectors.jsonl", import.meta.url), "utf8").trim().split("\n").map((l) => JSON.parse(l));

test("the app's copy of the membership rules matches the relay", async () => {
  assert.ok(runs.length > 0);
  for (const run of runs) {
    const relay = new GroupRelay(new MapStorage());
    for (const [i, step] of run.steps.entries()) {
      const list = { ...step.list, primary: step.list.primary ?? undefined };
      let status = 200;
      try { await relay.setMembers(step.signer, list); } catch (e) { if (!(e instanceof RelayError)) throw e; status = e.status; }
      assert.equal(status, step.status, `seed ${run.seed}, publish ${i}`);
    }
    const final = ((await relay.members())?.members ?? []).map((m) => `${m.key} ${m.role}`).sort();
    assert.deepEqual(final, run.final.map((m) => `${m.key} ${m.role}`).sort(), `seed ${run.seed}: final list`);
  }
});
