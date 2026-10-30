import assert from "node:assert/strict";
import { test } from "node:test";
import config from "../config.js";
import { systemPrompt } from "../src/prompt.js";

test("the system prompt carries the site's content, the safety line and the rules", () => {
  const p = systemPrompt(config);
  assert.ok(p.includes(config.content));
  assert.ok(p.includes(config.safetyLine));
  assert.ok(p.includes(config.elsewhere));
  assert.ok(p.includes("Never tell anyone that help is coming"));
  assert.ok(p.includes("never say or imply that it replaces them"));
  assert.ok(p.includes("Answer only from the site content"));
  assert.ok(p.includes("plain text only"));
});

test("the site's config says what the bot must never soften", () => {
  assert.match(config.safetyLine, /999/);
  assert.match(config.safetyLine, /does not replace/);
  assert.match(config.content, /does not replace 999/);
  assert.ok(!/delivered tick|help is on the way/i.test(config.content.replace(/no "delivered" tick/, "")));
});
