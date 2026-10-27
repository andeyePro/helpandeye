import assert from "node:assert/strict";
import { test } from "node:test";
import { configured, payload, providerToken, push } from "../src/apns.js";

async function env() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  // A key made for this test only. The PEM label is built from parts so no key-shaped text is committed.
  const label = ["PRIVATE", "KEY"].join(" ");
  const pem = `-----BEGIN ${label}-----\n${btoa(String.fromCharCode(...der))}\n-----END ${label}-----\n`;
  return { pair, env: { APNS_KEY: pem, APNS_KEY_ID: "ABC123DEFG", APNS_TEAM_ID: "TEAM123456", APNS_TOPIC: "org.andeye.helpandi" } };
}

const token = { token: "a".repeat(64), sandbox: true };

test("push is off until every secret is set", async () => {
  assert.equal(configured({}), false);
  let called = false;
  assert.equal(await push({}, token, "call", { fetchImpl: async () => { called = true; } }), 0);
  assert.equal(called, false);
});

test("the provider token is an ES256 JWT that verifies with the key", async () => {
  const { pair, env: e } = await env();
  const jwt = await providerToken(e, 1_793_000_000);
  const [h, c, s] = jwt.split(".");
  const dec = (x) => JSON.parse(Buffer.from(x, "base64url").toString());
  assert.deepEqual(dec(h), { alg: "ES256", kid: "ABC123DEFG" });
  assert.deepEqual(dec(c), { iss: "TEAM123456", iat: 1_793_000_000 });
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, Buffer.from(s, "base64url"), new TextEncoder().encode(`${h}.${c}`));
  assert.equal(ok, true);
});

test("a call is a visible time-sensitive push that names nobody; quiet only wakes", async () => {
  const { env: e } = await env();
  const seen = [];
  const fetchImpl = async (url, init) => { seen.push({ url, init }); return { status: 200 }; };
  assert.equal(await push(e, token, "call", { fetchImpl, now: 1_793_000_000_000 }), 200);
  assert.equal(await push(e, { ...token, sandbox: false }, "quiet", { fetchImpl, now: 1_793_000_000_000 }), 200);
  assert.equal(seen[0].url, `https://api.sandbox.push.apple.com/3/device/${"a".repeat(64)}`);
  assert.equal(seen[0].init.headers["apns-push-type"], "alert");
  assert.equal(seen[0].init.headers["apns-topic"], "org.andeye.helpandi");
  assert.equal(JSON.parse(seen[0].init.body).aps["interruption-level"], "time-sensitive");
  assert.equal(seen[1].url.startsWith("https://api.push.apple.com/"), true);
  assert.equal(seen[1].init.headers["apns-push-type"], "background");
  assert.deepEqual(payload("quiet"), { aps: { "content-available": 1 } });
  assert.doesNotMatch(JSON.stringify(payload("call")), /unit|name|[0-9]{5}/);
});

test("a bad token or a failed request sends nothing and reports 0", async () => {
  const { env: e } = await env();
  assert.equal(await push(e, { token: "nope" }, "call", { fetchImpl: async () => ({ status: 200 }) }), 0);
  assert.equal(await push(e, token, "call", { fetchImpl: async () => { throw new Error("down"); } }), 0);
});
