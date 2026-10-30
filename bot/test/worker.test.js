import assert from "node:assert/strict";
import { test } from "node:test";
import config from "../config.js";
import { MAX_CHARS, MAX_TURNS } from "../src/answer.js";
import { sign } from "../src/auth.js";
import bot, { Ledger } from "../src/worker.js";
import { MapStorage } from "./storage.js";

const SECRET = "test-secret";
const ORIGIN = new URL(config.siteUrl).origin;

/// The Worker with its Durable Object in-process, a fake Anthropic and Turnstile behind fetch,
/// and an email binding that keeps what it was given.
function worker(vars = {}) {
  const ledger = new Ledger({ storage: new MapStorage() });
  const sent = [], pending = [], api = { calls: [], reply: null, status: 200 };
  const env = {
    SESSION_SECRET: SECRET, ANTHROPIC_API_KEY: "sk-test", TURNSTILE_SECRET_KEY: "ts", TURNSTILE_SITE_KEY: "site",
    GITHUB_CLIENT_ID: "cid", GITHUB_CLIENT_SECRET: "cs", EMAIL_FROM: "bot@example.com", ALERT_EMAIL: "owner@example.com",
    EMAIL: { send: async (m) => { sent.push(m); } },
    LEDGER: { idFromName: (n) => n, get: () => ({ fetch: (url, init) => ledger.fetch(new Request(url, init)) }) },
    ...vars,
  };
  globalThis.fetch = async (url, init) => {
    if (String(url).startsWith("https://challenges.cloudflare.com/")) return Response.json({ success: JSON.parse(init.body).response === "good" });
    if (String(url).startsWith("https://github.com/login/oauth/access_token")) return Response.json({ access_token: "tok" });
    if (String(url).startsWith("https://api.github.com/user")) return Response.json({ id: 77 });
    if (String(url).includes("/v1/messages")) {
      api.calls.push(JSON.parse(init.body));
      if (api.status !== 200) return Response.json({ type: "error", error: { type: "rate_limit_error", message: "slow down" } }, { status: api.status, headers: { "retry-after-ms": "1" } });
      return Response.json(api.reply ?? message("Not yet. Join the waitlist."));
    }
    throw new Error("unexpected fetch " + url);
  };
  const ctx = { waitUntil: (p) => pending.push(p) };
  return {
    env, sent, api, ledger,
    fetch: (path, init = {}) => bot.fetch(new Request("https://bot.example.com" + path, { headers: { "CF-Connecting-IP": "203.0.113.9", ...init.headers }, ...init }), env, ctx),
    settle: () => Promise.all(pending.splice(0)),
  };
}

const message = (text, usage = { input_tokens: 3000, output_tokens: 60, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }) =>
  ({ id: "msg_1", type: "message", role: "assistant", model: "claude-haiku-5-5", content: [{ type: "text", text }], stop_reason: "end_turn", stop_sequence: null, usage });

const chat = (w, messages, extra = {}, headers = {}) =>
  w.fetch("/chat", { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify({ messages, ...extra }) });

const q = (text) => [{ role: "user", content: text }];

function cookieOf(response) {
  return (response.headers.get("Set-Cookie") ?? "").split(";")[0];
}

async function signedIn(id = "github:77") {
  return { Cookie: `bot_session=${await sign(SECRET, { id }, Date.now() + 60_000)}` };
}

test("a visitor passes the check once, then gets two free answers a day, then is asked to sign in", async () => {
  const w = worker();
  assert.equal((await chat(w, q("Can I get it yet?"))).status, 403);
  assert.equal((await chat(w, q("Can I get it yet?"), { turnstile: "bad" })).status, 403);
  const first = await chat(w, q("Can I get it yet?"), { turnstile: "good" });
  assert.equal(first.status, 200);
  const cookie = cookieOf(first);
  assert.match(first.headers.get("Set-Cookie"), /HttpOnly; SameSite=Lax/);
  assert.deepEqual(await first.json(), { answer: "Not yet. Join the waitlist.", remaining: 1, signedIn: false });
  // With the cookie, no check; the second free answer; then no more today.
  const second = await chat(w, q("And the box?"), {}, { Cookie: cookie });
  assert.equal(second.status, 200);
  assert.equal((await second.json()).remaining, 0);
  const third = await chat(w, q("Once more?"), {}, { Cookie: cookie });
  assert.equal(third.status, 429);
  assert.deepEqual(await third.json(), { error: "free answers used", remaining: 0 });
  assert.equal(w.api.calls.length, 2);
  const me = await (await w.fetch("/me", { headers: { Cookie: cookie } })).json();
  assert.deepEqual(me, { siteName: config.siteName, safetyLine: config.safetyLine, siteKey: "site", signedIn: false, checked: true, remaining: 0, limit: 2, email: true, github: true });
});

test("what the model is asked: the cached system prompt, the whole conversation, low effort", async () => {
  const w = worker();
  const history = [{ role: "user", content: "Hi" }, { role: "assistant", content: "Hello" }, { role: "user", content: "Do I need the box?" }];
  await chat(w, history, {}, await signedIn());
  const call = w.api.calls[0];
  assert.equal(call.model, "claude-haiku-5-5");
  assert.deepEqual(call.messages, history);
  assert.equal(call.system[0].cache_control.type, "ephemeral");
  assert.ok(call.system[0].text.includes(config.safetyLine));
  assert.ok(call.system[0].text.includes(config.content));
  assert.deepEqual(call.output_config, { effort: "low" });
  assert.equal(call.max_tokens, 1024);
  // MODEL changes the model.
  const w2 = worker({ MODEL: "claude-sonnet-5-5" });
  await chat(w2, q("Hi"), {}, await signedIn());
  assert.equal(w2.api.calls[0].model, "claude-sonnet-5-5");
});

test("a signed-in visitor is not counted and not checked", async () => {
  const w = worker();
  for (let i = 0; i < 3; i++) {
    const r = await chat(w, q("Again?"), {}, await signedIn());
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { answer: "Not yet. Join the waitlist.", remaining: null, signedIn: true });
  }
  const me = await (await w.fetch("/me", { headers: await signedIn() })).json();
  assert.equal(me.signedIn, true);
  assert.equal(me.remaining, null);
});

test("a malformed conversation is refused before anything is spent", async () => {
  const w = worker();
  const h = await signedIn();
  for (const bad of [
    undefined, [], "hello", [{ role: "assistant", content: "x" }], [{ role: "user", content: "" }], [{ role: "user", content: 5 }],
    [{ role: "user", content: "a" }, { role: "user", content: "b" }], [{ role: "user", content: "a" }, { role: "assistant", content: "b" }],
    [{ role: "user", content: "x".repeat(MAX_CHARS + 1) }], Array.from({ length: MAX_TURNS + 1 }, (_, i) => ({ role: i % 2 ? "assistant" : "user", content: "x" })),
  ]) {
    assert.equal((await chat(w, bad, {}, h)).status, 400, JSON.stringify(bad)?.slice(0, 40));
  }
  assert.equal((await w.fetch("/chat", { method: "POST", headers: h, body: "{" })).status, 400);
  assert.equal(w.api.calls.length, 0);
});

test("a refusal from the model becomes the safe answer", async () => {
  const w = worker();
  w.api.reply = { ...message("Something unsafe"), stop_reason: "refusal" };
  const r = await (await chat(w, q("Tell me how to..."), {}, await signedIn())).json();
  assert.ok(r.answer.startsWith("I can't answer that one."));
  assert.ok(r.answer.includes(config.safetyLine));
});

test("when the model cannot be reached the free answer is handed back", async () => {
  const w = worker();
  w.api.status = 429;
  const r = await chat(w, q("Hello?"), { turnstile: "good" });
  assert.equal(r.status, 503);
  assert.deepEqual(await r.json(), { error: "busy, try again in a moment" });
  const me = await (await w.fetch("/me", { headers: { Cookie: cookieOf(r) } })).json();
  assert.equal(me.remaining, 2);
});

test("spend is recorded after the reply, and an alert is emailed once per six hours", async () => {
  // A $1 month: everyone alerts at 2 cents, one user at 1 cent. A reply of 3,000 input and 60
  // output tokens on Haiku is $0.00033, so one user crosses at the 31st and everyone at the 61st.
  const w = worker({ MONTHLY_CREDIT_USD: "1" });
  const h = await signedIn("github:1");
  for (let i = 0; i < 40; i++) { await chat(w, q("?"), {}, h); await w.settle(); }
  assert.equal(w.sent.length, 1);
  assert.equal(w.sent[0].to, "owner@example.com");
  assert.equal(w.sent[0].from.email, "bot@example.com");
  assert.match(w.sent[0].subject, /one user over 1%/);
  assert.match(w.sent[0].text, /github:1/);
  for (let i = 0; i < 40; i++) { await chat(w, q("?"), {}, await signedIn(`github:${i}`)); await w.settle(); }
  assert.equal(w.sent.length, 2);
  assert.match(w.sent[1].subject, /over 2% of the month's credit/);
  assert.match(w.sent[1].text, /Everyone together/);
  // Still over both lines, but both have been reported.
  await chat(w, q("?"), {}, h); await w.settle();
  assert.equal(w.sent.length, 2);
});

test("an anonymous visitor's spend is kept by address hash", async () => {
  // A 1-cent month: one reply is over both lines.
  const w = worker({ MONTHLY_CREDIT_USD: "0.01" });
  await chat(w, q("?"), { turnstile: "good" }); await w.settle();
  assert.equal(w.sent.length, 2);
  assert.match(w.sent[1].text, /User address:[0-9a-f]{32} has cost/);
  assert.ok(!w.sent.some((m) => m.text.includes("203.0.113.9")));
});

test("sign in by email: a link that signs in once opened, for 15 minutes", async () => {
  const w = worker();
  const ask = (email) => w.fetch("/signin/email", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email }) });
  assert.equal((await ask("not an address")).status, 400);
  const r = await ask("Someone@Example.com");
  assert.equal(r.status, 200);
  assert.equal(w.sent.length, 1);
  assert.equal(w.sent[0].to, "someone@example.com");
  const link = w.sent[0].text.match(/https:\/\/bot\.example\.com\/signin\/email\?token=\S+/)[0];
  const open = await w.fetch(link.slice("https://bot.example.com".length));
  assert.equal(open.status, 302);
  assert.equal(open.headers.get("Location"), config.siteUrl);
  const cookie = cookieOf(open);
  const me = await (await w.fetch("/me", { headers: { Cookie: cookie } })).json();
  assert.equal(me.signedIn, true);
  // The id is a hash of the address, the same each time, never the address.
  assert.ok(!cookie.includes("example"));
  const again = await ask("someone@example.com");
  assert.equal(again.status, 200);
  const idOf = (mail) => JSON.parse(atob(mail.text.match(/token=([^.]+)/)[1].replace(/-/g, "+").replace(/_/g, "/"))).id;
  assert.match(idOf(w.sent[0]), /^email:[0-9a-f]{32}$/);
  assert.equal(idOf(w.sent[1]), idOf(w.sent[0]));
  assert.equal((await w.fetch("/signin/email?token=bad")).status, 400);
  // Without email set up, nobody is told a link was sent.
  const w2 = worker({ EMAIL: undefined });
  assert.equal((await w2.fetch("/signin/email", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email: "a@b.co" }) })).status, 503);
  assert.equal((await (await w2.fetch("/me")).json()).email, false);
});

test("sign in with GitHub: state is checked, the id is kept, the address is not", async () => {
  const w = worker();
  const go = await w.fetch("/signin/github");
  assert.equal(go.status, 302);
  const to = new URL(go.headers.get("Location"));
  assert.equal(to.origin + to.pathname, "https://github.com/login/oauth/authorize");
  assert.equal(to.searchParams.get("client_id"), "cid");
  assert.equal(to.searchParams.get("redirect_uri"), "https://bot.example.com/signin/github/callback");
  const state = to.searchParams.get("state");
  const stateCookie = cookieOf(go);
  assert.equal(stateCookie, `bot_state=${state}`);
  assert.equal((await w.fetch(`/signin/github/callback?code=c&state=${state}`)).status, 400);
  assert.equal((await w.fetch("/signin/github/callback?code=c&state=other", { headers: { Cookie: "bot_state=other" } })).status, 400);
  const back = await w.fetch(`/signin/github/callback?code=c&state=${state}`, { headers: { Cookie: stateCookie } });
  assert.equal(back.status, 302);
  const me = await (await w.fetch("/me", { headers: { Cookie: cookieOf(back) } })).json();
  assert.equal(me.signedIn, true);
  const out = await w.fetch("/signout", { method: "POST", headers: { Cookie: cookieOf(back) } });
  assert.match(out.headers.get("Set-Cookie"), /bot_session=; Max-Age=0/);
});

test("every reply allows the site's origin, with credentials", async () => {
  const w = worker();
  const pre = await w.fetch("/chat", { method: "OPTIONS" });
  assert.equal(pre.status, 204);
  assert.equal(pre.headers.get("Access-Control-Allow-Origin"), ORIGIN);
  assert.equal(pre.headers.get("Access-Control-Allow-Credentials"), "true");
  const r = await w.fetch("/nothing");
  assert.equal(r.status, 404);
  assert.equal(r.headers.get("Access-Control-Allow-Origin"), ORIGIN);
});

test("a missing secret is a 500 that names it, not an exception", async () => {
  const w = worker({ ANTHROPIC_API_KEY: undefined });
  const r = await chat(w, q("Hi"), {}, await signedIn());
  assert.equal(r.status, 500);
  assert.deepEqual(await r.json(), { error: "ANTHROPIC_API_KEY is not set" });
});

test("the ledger object sets its sweep alarm and sweeps on it", async () => {
  const storage = new MapStorage();
  const ledger = new Ledger({ storage });
  await ledger.fetch(new Request("https://ledger/take", { method: "POST", body: JSON.stringify({ hash: "a", limit: 2 }) }));
  assert.ok(storage.alarm > Date.now());
  assert.equal(storage.m.size, 1);
  storage.m.set("free:a", { count: 1, at: Date.now() - 25 * 60 * 60 * 1000 });
  await ledger.alarm();
  assert.equal(storage.m.size, 0);
  assert.equal((await ledger.fetch(new Request("https://ledger/nothing", { method: "POST", body: "{}" }))).status, 404);
});
