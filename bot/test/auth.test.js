import assert from "node:assert/strict";
import { test } from "node:test";
import { addressHash, cookies, githubAuthUrl, githubUserId, setCookie, sign, turnstileOk, verify } from "../src/auth.js";

const SECRET = "test-secret";

test("a signed token carries its payload until it expires, and not if altered", async () => {
  const now = 1_793_000_000_000;
  const token = await sign(SECRET, "session", { id: "github:1" }, now + 1000);
  assert.deepEqual(await verify(SECRET, "session", token, now), { id: "github:1", use: "session", exp: now + 1000 });
  assert.equal(await verify(SECRET, "session", token, now + 1000), null);
  assert.equal(await verify("other", "session", token, now), null);
  const [body, sig] = token.split(".");
  assert.equal(await verify(SECRET, "session", body + "x." + sig, now), null);
  assert.equal(await verify(SECRET, "session", body + "." + sig.slice(0, -2) + "AA", now), null);
  assert.equal(await verify(SECRET, "session", "nonsense", now), null);
  assert.equal(await verify(SECRET, "session", undefined, now), null);
});

test("a token made for one thing is not taken for another", async () => {
  const now = 1_793_000_000_000;
  const link = await sign(SECRET, "link", { id: "email:abc" }, now + 1000);
  assert.equal(await verify(SECRET, "session", link, now), null);
  assert.equal(await verify(SECRET, "state", link, now), null);
  assert.ok(await verify(SECRET, "link", link, now));
  // A payload that names a use itself is overridden by the one it is signed for.
  const forged = await sign(SECRET, "link", { id: "email:abc", use: "session" }, now + 1000);
  assert.equal(await verify(SECRET, "session", forged, now), null);
});

test("the address hash is the same all day, and different the next day and with another secret", async () => {
  const day = Date.UTC(2026, 9, 30, 10);
  const a = await addressHash(SECRET, "203.0.113.9", day);
  assert.match(a, /^[0-9a-f]{32}$/);
  assert.equal(await addressHash(SECRET, "203.0.113.9", day + 13 * 60 * 60 * 1000), a);
  assert.notEqual(await addressHash(SECRET, "203.0.113.9", day + 24 * 60 * 60 * 1000), a);
  assert.notEqual(await addressHash("other", "203.0.113.9", day), a);
  assert.notEqual(await addressHash(SECRET, "203.0.113.10", day), a);
});

test("cookies are read by name and set first-party only", () => {
  const request = new Request("https://bot", { headers: { Cookie: "a=1; bot_session=x.y; b=2" } });
  assert.deepEqual(cookies(request), { a: "1", bot_session: "x.y", b: "2" });
  assert.deepEqual(cookies(new Request("https://bot")), {});
  assert.equal(setCookie("bot_session", "x.y", 60), "bot_session=x.y; Max-Age=60; Path=/; Secure; HttpOnly; SameSite=Lax");
});

test("Turnstile is asked with the secret, the token and the address", async () => {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    return Response.json({ success: calls[0].body.response === "good" });
  };
  try {
    assert.equal(await turnstileOk("sk", "good", "203.0.113.9"), true);
    assert.deepEqual(calls[0], { url: "https://challenges.cloudflare.com/turnstile/v0/siteverify", body: { secret: "sk", response: "good", remoteip: "203.0.113.9" } });
    assert.equal(await turnstileOk("sk", "", "203.0.113.9"), false);
    assert.equal(calls.length, 1);
    globalThis.fetch = async () => { throw new Error("down"); };
    assert.equal(await turnstileOk("sk", "good", "203.0.113.9"), false);
  } finally {
    globalThis.fetch = real;
  }
});

test("GitHub: the code is traded for the user's id", async () => {
  const real = globalThis.fetch;
  const env = { GITHUB_CLIENT_ID: "cid", GITHUB_CLIENT_SECRET: "cs" };
  globalThis.fetch = async (url, init) => {
    if (url === "https://github.com/login/oauth/access_token") {
      const b = JSON.parse(init.body);
      assert.deepEqual(b, { client_id: "cid", client_secret: "cs", code: "c0de", redirect_uri: "https://bot/cb" });
      return Response.json({ access_token: "tok" });
    }
    assert.equal(init.headers.Authorization, "Bearer tok");
    return Response.json({ id: 4242, login: "someone" });
  };
  try {
    assert.equal(await githubUserId(env, "c0de", "https://bot/cb"), "4242");
    globalThis.fetch = async () => Response.json({ error: "bad_verification_code" });
    assert.equal(await githubUserId(env, "bad", "https://bot/cb"), null);
  } finally {
    globalThis.fetch = real;
  }
  assert.equal(githubAuthUrl("cid", "https://bot/cb", "st"), "https://github.com/login/oauth/authorize?client_id=cid&redirect_uri=https%3A%2F%2Fbot%2Fcb&state=st");
});
