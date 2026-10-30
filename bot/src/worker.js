import config from "../config.js";
import { answer, BotError, conversation, DEFAULT_MODEL } from "./answer.js";
import { addressHash, cookies, githubAuthUrl, githubUserId, setCookie, sign, turnstileOk, verify } from "./auth.js";
import { configured as emailOn, send } from "./email.js";
import { Ledger as LedgerLogic } from "./ledger.js";
import { systemPrompt } from "./prompt.js";

// Routes (the widget calls the first two; the rest are sign-in):
//   GET  /me                       who the visitor is and how many free answers are left
//   POST /chat                     {messages, turnstile?} -> {answer, remaining}
//   POST /signin/email             {email} -> a sign-in link is emailed
//   GET  /signin/email?token=...   the link: signs in and returns to the site
//   GET  /signin/github            to GitHub
//   GET  /signin/github/callback   back from GitHub: signs in and returns to the site
//   POST /signout
// widget.js is a static asset, served before any of these.

const SESSION = "bot_session";
const STATE = "bot_state";
const SESSION_S = 30 * 24 * 60 * 60;
const LINK_S = 15 * 60;
const FREE_A_DAY = 2;
// Shares of the month's credit in any six hours that get an alert: everyone together, one user.
const ALERT_EVERYONE = 0.02;
const ALERT_USER = 0.01;

const SYSTEM = systemPrompt(config);

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const origin = new URL(config.siteUrl).origin;
    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }), origin);
    let response;
    try {
      response = await route(request, url, env, ctx);
    } catch (e) {
      if (e instanceof BotError) response = json(e.status, { error: e.message });
      else if (e instanceof SyntaxError) response = json(400, { error: "bad JSON" });
      else throw e;
    }
    return cors(response, origin);
  },
};

async function route(request, url, env, ctx) {
  const m = request.method, p = url.pathname;
  const secret = need(env, "SESSION_SECRET");
  const session = await verify(secret, cookies(request)[SESSION]);
  const address = request.headers.get("CF-Connecting-IP") ?? "";
  const hash = await addressHash(secret, address);
  const free = Number(env.FREE_ANSWERS_A_DAY) || FREE_A_DAY;

  if (m === "GET" && p === "/me") {
    const remaining = session?.id ? null : await ledger(env, "/remaining", { hash, limit: free });
    return json(200, {
      siteName: config.siteName, safetyLine: config.safetyLine, siteKey: env.TURNSTILE_SITE_KEY ?? "",
      signedIn: Boolean(session?.id), checked: Boolean(session), remaining: remaining?.remaining ?? null, limit: free, email: emailOn(env),
      github: Boolean(env.GITHUB_CLIENT_ID),
    });
  }

  if (m === "POST" && p === "/chat") {
    const body = await request.json();
    const messages = conversation(body?.messages);
    const headers = {};
    let who;
    if (session?.id) who = session.id;
    else {
      // A visitor proves they are a person once; the cookie says so for a day.
      if (!session) {
        if (!(await turnstileOk(need(env, "TURNSTILE_SECRET_KEY"), body?.turnstile, address))) throw new BotError(403, "check failed");
        headers["Set-Cookie"] = setCookie(SESSION, await sign(secret, { anon: true }, Date.now() + 24 * 60 * 60 * 1000), 24 * 60 * 60);
      }
      who = `address:${hash}`;
    }
    const taken = session?.id ? null : await ledger(env, "/take", { hash, limit: free });
    if (taken && !taken.allowed) return json(429, { error: "free answers used", remaining: 0 }, headers);
    let reply;
    try {
      reply = await answer({ apiKey: need(env, "ANTHROPIC_API_KEY"), model: env.MODEL || DEFAULT_MODEL, system: SYSTEM, messages, refusal: refusal() });
    } catch (e) {
      if (taken) await ledger(env, "/giveBack", { hash });
      throw e;
    }
    ctx.waitUntil(account(env, who, reply.usd));
    return json(200, { answer: reply.text, remaining: taken?.remaining ?? null, signedIn: Boolean(session?.id) }, headers);
  }

  if (m === "POST" && p === "/signin/email") {
    const email = String((await request.json())?.email ?? "").trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) throw new BotError(400, "bad email");
    // The id is a hash, so the address itself is never kept.
    const id = `email:${await addressHash(secret, email, 0)}`;
    const token = await sign(secret, { id }, Date.now() + LINK_S * 1000);
    const link = `${url.origin}/signin/email?token=${token}`;
    const sent = await send(env, email, `Sign in to ask about ${config.siteName}`,
      `Open this link to sign in and keep asking questions about ${config.siteName}:\n\n${link}\n\nIt works for 15 minutes. If you did not ask for it, ignore this email.`);
    if (!sent) throw new BotError(503, "email is not set up");
    return json(200, { sent: true });
  }

  if (m === "GET" && p === "/signin/email") {
    const payload = await verify(secret, url.searchParams.get("token"));
    if (!payload?.id) return text(400, "This link has expired. Ask for a new one.");
    return signedIn(secret, payload.id);
  }

  if (m === "GET" && p === "/signin/github") {
    const state = await sign(secret, { s: crypto.randomUUID() }, Date.now() + LINK_S * 1000);
    return new Response(null, {
      status: 302,
      headers: { Location: githubAuthUrl(need(env, "GITHUB_CLIENT_ID"), `${url.origin}/signin/github/callback`, state), "Set-Cookie": setCookie(STATE, state, LINK_S) },
    });
  }

  if (m === "GET" && p === "/signin/github/callback") {
    const state = url.searchParams.get("state");
    if (!state || state !== cookies(request)[STATE] || !(await verify(secret, state))) return text(400, "Sign-in did not match. Try again.");
    const id = await githubUserId(env, url.searchParams.get("code"), `${url.origin}/signin/github/callback`);
    if (!id) return text(400, "GitHub did not sign you in. Try again.");
    return signedIn(secret, `github:${id}`);
  }

  if (m === "POST" && p === "/signout") return json(200, { ok: true }, { "Set-Cookie": setCookie(SESSION, "", 0) });

  return json(404, { error: "not found" });
}

async function signedIn(secret, id) {
  const token = await sign(secret, { id }, Date.now() + SESSION_S * 1000);
  return new Response(null, { status: 302, headers: { Location: config.siteUrl, "Set-Cookie": setCookie(SESSION, token, SESSION_S) } });
}

function refusal() {
  return `I can't answer that one. ${config.elsewhere} ${config.safetyLine}`;
}

/// Adds a reply's cost to the ledger and emails any alert it raises.
async function account(env, who, usd) {
  const credit = Number(env.MONTHLY_CREDIT_USD) || 200;
  let alerts;
  try {
    alerts = await ledger(env, "/spend", { who, usd, thresholds: { everyone: credit * ALERT_EVERYONE, user: credit * ALERT_USER } });
  } catch (e) {
    console.error("spend not recorded", e?.message ?? e);
    return;
  }
  for (const a of alerts) {
    const subject = a.who === "*" ? `${config.siteName} bot: over ${ALERT_EVERYONE * 100}% of the month's credit in six hours`
      : `${config.siteName} bot: one user over ${ALERT_USER * 100}% of the month's credit in six hours`;
    const body = `${a.who === "*" ? "Everyone together" : `User ${a.who}`} has cost an estimated $${a.usd.toFixed(2)} in the last six hours (alert level $${a.threshold.toFixed(2)}, monthly credit $${credit}).\n\nThis is sent at most once every six hours. Check the Console's usage page for the real figure.`;
    if (env.ALERT_EMAIL) await send(env, env.ALERT_EMAIL, subject, body);
  }
}

async function ledger(env, path, body) {
  const stub = env.LEDGER.get(env.LEDGER.idFromName("all"));
  return (await stub.fetch(`https://ledger${path}`, { method: "POST", body: JSON.stringify(body) })).json();
}

function need(env, name) {
  if (!env[name]) throw new BotError(500, `${name} is not set`);
  return env[name];
}

function cors(response, origin) {
  const out = new Response(response.body, response);
  out.headers.set("Access-Control-Allow-Origin", origin);
  out.headers.set("Access-Control-Allow-Credentials", "true");
  out.headers.set("Access-Control-Allow-Headers", "Content-Type");
  out.headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  out.headers.set("Vary", "Origin");
  return out;
}

function json(status, value, headers = {}) {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json", ...headers } });
}

function text(status, value) {
  return new Response(value, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });
}

/// The one Durable Object holding every count. Each request is one of the Ledger's calls.
export class Ledger {
  constructor(state) {
    this.state = state;
    this.ledger = new LedgerLogic(state.storage);
  }

  async fetch(request) {
    const path = new URL(request.url).pathname;
    const body = await request.json();
    let result;
    if (path === "/take") result = await this.ledger.take(body.hash, body.limit);
    else if (path === "/giveBack") { await this.ledger.giveBack(body.hash); result = { ok: true }; }
    else if (path === "/remaining") result = { remaining: await this.ledger.remaining(body.hash, body.limit) };
    else if (path === "/spend") result = await this.ledger.spend(body.who, body.usd, body.thresholds);
    else return json(404, { error: "not found" });
    if ((await this.state.storage.getAlarm()) === null) await this.state.storage.setAlarm(Date.now() + 60 * 60 * 1000);
    return json(200, result);
  }

  async alarm() {
    const next = await this.ledger.sweep();
    if (next !== null) await this.state.storage.setAlarm(next);
  }
}
