import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { GroupRelay, RelayError } from "../src/relay.js";
import { MapStorage } from "./storage.js";

// The fuzz test of the app (app/helpandeyeCore, EngineFuzzTests) uses a Swift copy of the relay's
// membership rules. These are the member-list publishes from some of its runs, with what that copy
// said; the real relay must say the same and end with the same list.
// Regenerate: HELPA_RELAY_LOG=<file> HELPA_FUZZ_SEEDS=4 swift test --filter EngineFuzzTests

const runs = readFileSync(new URL("./model-vectors.jsonl", import.meta.url), "utf8").trim().split("\n").map((l) => JSON.parse(l));

test("the app's copy of the membership rules matches the relay", async () => {
  assert.ok(runs.length > 0);
  for (const run of runs) {
    const relay = new GroupRelay(new MapStorage());
    for (const [i, step] of run.steps.entries()) {
      const list = { ...step.list, primary: step.list.primary ?? undefined };
      if (list.primary === null) delete list.primary;
      let status = 200;
      const group = step.group ? Uint8Array.from(atob(step.group), (c) => c.charCodeAt(0)) : null;
      try { await relay.setMembers(step.signer, list, group); } catch (e) { if (!(e instanceof RelayError)) throw e; status = e.status; }
      assert.equal(status, step.status, `seed ${run.seed}, publish ${i}`);
    }
    const final = ((await relay.members())?.members ?? []).map((m) => `${m.key} ${m.role}`).sort();
    assert.deepEqual(final, run.final.map((m) => `${m.key} ${m.role}`).sort(), `seed ${run.seed}: final list`);
  }
});
