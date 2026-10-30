import assert from "node:assert/strict";
import { test } from "node:test";
import config from "../config.js";

// Just enough of a page for the widget: elements, attributes, text and listeners.
class Node {
  constructor(tag) { this.tag = tag; this.children = []; this.attrs = {}; this.listeners = {}; this.textContent = ""; this.value = ""; this.disabled = false; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return this.attrs[k] ?? null; }
  appendChild(c) { this.children.push(c); return c; }
  addEventListener(t, f) { (this.listeners[t] ??= []).push(f); }
  focus() {}
  submit() { for (const f of this.listeners.submit ?? []) f({ preventDefault() {} }); }
  find(pred) { if (pred(this)) return this; for (const c of this.children) { const r = c.find(pred); if (r) return r; } return null; }
  text() { return [this.textContent, ...this.children.map((c) => c.text())].filter(Boolean).join(" "); }
}

const tick = () => new Promise((r) => setTimeout(r, 0));

test("the widget shows the safety line, labels its fields, checks once, asks, and offers sign-in", async () => {
  const box = new Node("div");
  const head = new Node("head");
  const calls = [];
  let me = { siteName: config.siteName, safetyLine: config.safetyLine, siteKey: "site", signedIn: false, checked: false, remaining: 2, limit: 2, email: true, github: true };
  const replies = [];
  globalThis.document = {
    currentScript: { src: "https://bot.example.com/widget.js", getAttribute: () => null },
    querySelector: (s) => (s === "#site-bot" ? box : null),
    createElement: (t) => new Node(t),
    head,
  };
  globalThis.window = globalThis;
  globalThis.fetch = async (url, init) => {
    calls.push({ url, body: init.body && JSON.parse(init.body), credentials: init.credentials });
    if (url.endsWith("/me")) return Response.json(me);
    const r = replies.shift();
    return Response.json(r.body, { status: r.status });
  };
  await import("../public/widget.js");
  await tick(); await tick();

  const text = box.text();
  assert.ok(text.includes(config.safetyLine));
  assert.ok(text.includes("2 free answers today, then sign in."));
  const label = box.find((n) => n.tag === "label" && n.attrs.for === "sb-q");
  assert.equal(label.text(), "Your question");
  const question = box.find((n) => n.attrs.id === "sb-q");
  assert.equal(question.tag, "textarea");
  const log = box.find((n) => n.attrs.role === "log");
  assert.equal(log.attrs["aria-live"], "polite");
  const signin = box.find((n) => n.attrs.class === "sb-signin");
  assert.equal(signin.attrs.hidden, "");
  // Turnstile's script is asked for, with a callback that renders the check.
  const ts = head.children.find((n) => n.tag === "script");
  assert.match(ts.attrs.src, /^https:\/\/challenges\.cloudflare\.com\/turnstile\/v0\/api\.js\?render=explicit&onload=sbTurnstile$/);
  let rendered = null;
  globalThis.turnstile = { render: (el, opts) => { rendered = opts; return 1; }, remove: () => {} };
  globalThis.sbTurnstile();
  assert.equal(rendered.sitekey, "site");

  // Asking before the check has passed only says to wait.
  const form = box.find((n) => n.attrs.class === "sb-form");
  const status = box.find((n) => n.attrs.role === "status");
  question.value = "Can I get it yet?";
  form.submit();
  await tick();
  assert.match(status.textContent, /wait for the check/);
  assert.equal(calls.length, 1);

  rendered.callback("tok");
  replies.push({ status: 200, body: { answer: "Not yet.\n\nJoin the waitlist.", remaining: 1, signedIn: false } });
  form.submit();
  await tick(); await tick(); await tick();
  assert.deepEqual(calls[1].body, { messages: [{ role: "user", content: "Can I get it yet?" }], turnstile: "tok" });
  assert.equal(calls[1].credentials, "include");
  assert.equal(log.children.length, 2);
  assert.equal(log.children[0].text(), "You Can I get it yet?");
  assert.equal(log.children[1].text(), `${config.siteName} Not yet. Join the waitlist.`);
  assert.equal(log.children[1].children.length, 3);
  assert.equal(status.textContent, "1 free answer today, then sign in.");
  assert.equal(question.value, "");

  // The next question carries the conversation, and no token: the cookie has it now.
  question.value = "And the box?";
  replies.push({ status: 429, body: { error: "free answers used", remaining: 0 } });
  form.submit();
  await tick(); await tick(); await tick();
  assert.deepEqual(calls[2].body.messages.map((m) => m.role), ["user", "assistant", "user"]);
  assert.equal(calls[2].body.turnstile, null);
  assert.equal(signin.attrs.hidden, undefined);
  assert.equal(form.attrs.hidden, "");
  assert.equal(box.find((n) => n.attrs.href === "https://bot.example.com/signin/github").text(), "Sign in with GitHub");

  // The email form posts the address and reports.
  const emailForm = box.find((n) => n.attrs.class === "sb-email");
  box.find((n) => n.attrs.id === "sb-email").value = "a@b.co";
  replies.push({ status: 200, body: { sent: true } });
  emailForm.submit();
  await tick(); await tick();
  assert.deepEqual(calls[3].body, { email: "a@b.co" });
  assert.match(status.textContent, /Open the link in the email/);
});
