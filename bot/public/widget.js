// The drop-in widget. One script tag and one element on the page:
//   <div id="site-bot"></div>
//   <script src="https://bot.example.com/widget.js" defer></script>
// data-container="#other" on the script tag names another element. Colours come from the
// page's own variables (--text, --panel, --accent and so on) where it has them.
(function () {
  var script = document.currentScript;
  var origin = new URL(script.src).origin;
  var box = document.querySelector(script.getAttribute("data-container") || "#site-bot");
  if (!box) return;

  var css = ".sb{color:var(--text,#eef1f6);max-width:var(--measure,720px);line-height:1.55}" +
    ".sb *{box-sizing:border-box}" +
    ".sb-safety{background:var(--panel,#131826);border:1px solid var(--line-soft,#1b2233);border-left:6px solid var(--accent,#009A44);border-radius:var(--radius,14px);padding:12px 16px;margin:0 0 1rem;font-weight:700}" +
    ".sb-log{display:grid;gap:10px;margin:0 0 1rem}" +
    ".sb-msg{margin:0;padding:12px 16px;border-radius:var(--radius,14px);background:var(--panel,#131826);border:1px solid var(--line-soft,#1b2233)}" +
    ".sb-msg p{margin:0 0 .6rem}.sb-msg p:last-child{margin:0}" +
    ".sb-you{background:transparent;border-color:var(--line,#232b40)}" +
    ".sb-who{display:block;font-size:.85rem;font-weight:700;color:var(--accent,#009A44);margin-bottom:.2rem}" +
    ".sb label{display:block;font-weight:700;margin:0 0 .4rem}" +
    ".sb textarea,.sb input{font:inherit;width:100%;min-height:44px;padding:10px 12px;border-radius:8px;border:1px solid var(--line,#232b40);background:var(--bg-deep,#090b11);color:inherit;margin:0 0 .8rem}" +
    ".sb-row{display:flex;flex-wrap:wrap;gap:12px;align-items:center;margin:0 0 .8rem}" +
    ".sb button,.sb-link{font:inherit;font-weight:700;min-height:44px;display:inline-flex;align-items:center;justify-content:center;padding:.6rem 1.4rem;border-radius:999px;border:1px solid transparent;background:var(--accent,#009A44);color:var(--bg,#0c0f16);cursor:pointer;text-decoration:none}" +
    ".sb button:disabled{opacity:.6;cursor:default}" +
    ".sb-ghost{background:transparent!important;color:inherit!important;border-color:var(--line,#232b40)!important}" +
    ".sb :focus-visible{outline:2px solid var(--accent,#009A44);outline-offset:3px}" +
    ".sb-status{margin:0 0 1rem;color:var(--muted,#a0a8ba)}" +
    ".sb-signin{border-top:1px solid var(--line-soft,#1b2233);padding-top:1rem}" +
    ".sb-signin p{margin:0 0 .8rem}" +
    ".sb-small{font-size:.85rem;color:var(--faint,#8a93a5);margin:1rem 0 0}";

  function el(tag, attrs, children) {
    var e = document.createElement(tag);
    for (var k in attrs || {}) {
      if (k === "text") e.textContent = attrs[k];
      else if (k === "hidden") { if (attrs[k]) e.setAttribute("hidden", ""); }
      else e.setAttribute(k, attrs[k]);
    }
    (children || []).forEach(function (c) { e.appendChild(c); });
    return e;
  }

  var safety = el("p", { class: "sb-safety" });
  var log = el("div", { class: "sb-log", role: "log", "aria-live": "polite", "aria-label": "Questions and answers" });
  var question = el("textarea", { id: "sb-q", rows: "3", maxlength: "2000", required: "", autocomplete: "off" });
  var check = el("div", { class: "sb-check" });
  var ask = el("button", { type: "submit", text: "Ask" });
  var form = el("form", { class: "sb-form" }, [
    el("label", { for: "sb-q", text: "Your question" }),
    question,
    el("div", { class: "sb-row" }, [check]),
    el("div", { class: "sb-row" }, [ask]),
  ]);
  var status = el("p", { class: "sb-status", role: "status" });
  var email = el("input", { id: "sb-email", type: "email", autocomplete: "email", required: "" });
  var emailButton = el("button", { type: "submit", text: "Email me a sign-in link" });
  var emailForm = el("form", { class: "sb-email" }, [el("label", { for: "sb-email", text: "Your email address" }), email, el("div", { class: "sb-row" }, [emailButton])]);
  var github = el("a", { class: "sb-link sb-ghost", href: origin + "/signin/github", text: "Sign in with GitHub" });
  var signin = el("div", { class: "sb-signin", hidden: true }, [
    el("p", { text: "You have had today's free answers. Sign in to keep asking; it costs nothing." }),
    emailForm,
    el("div", { class: "sb-row" }, [github]),
  ]);
  var small = el("p", { class: "sb-small", text: "Answers come from this website's own pages and may be wrong. Nothing you type is kept." });
  box.appendChild(el("style", { text: css }));
  box.appendChild(el("div", { class: "sb" }, [safety, log, form, status, signin, small]));

  var me = null, history = [], token = null, widgetId = null;

  function say(text) { status.textContent = text; }

  function add(who, cls, text) {
    var m = el("div", { class: "sb-msg " + cls }, [el("span", { class: "sb-who", text: who })]);
    text.split(/\n\s*\n/).forEach(function (para) { m.appendChild(el("p", { text: para.replace(/\s*\n\s*/g, " ") })); });
    log.appendChild(m);
    return m;
  }

  function remainingText() {
    if (me.signedIn) return "Signed in. Ask as much as you like.";
    if (me.remaining === 0) return "";
    return me.remaining + " free " + (me.remaining === 1 ? "answer" : "answers") + " today, then sign in.";
  }

  function showSignin(on) {
    if (on) { signin.removeAttribute("hidden"); form.setAttribute("hidden", ""); }
    else { signin.setAttribute("hidden", ""); form.removeAttribute("hidden"); }
    if (!me.email) emailForm.setAttribute("hidden", "");
    if (!me.github) github.setAttribute("hidden", "");
  }

  // Turnstile proves the visitor is a person once; after that the cookie does.
  function needCheck() { return me && !me.signedIn && !me.checked; }

  function renderCheck() {
    if (!needCheck() || !me.siteKey || widgetId !== null) return;
    if (!window.turnstile) {
      window.sbTurnstile = renderCheck;
      var s = el("script", { src: "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=sbTurnstile", async: "", defer: "" });
      document.head.appendChild(s);
      return;
    }
    widgetId = window.turnstile.render(check, {
      sitekey: me.siteKey,
      theme: "auto",
      callback: function (t) { token = t; },
      "expired-callback": function () { token = null; },
      "error-callback": function () { token = null; },
    });
  }

  function clearCheck() {
    if (widgetId !== null && window.turnstile) window.turnstile.remove(widgetId);
    widgetId = null;
    token = null;
    check.textContent = "";
  }

  function call(path, body) {
    return fetch(origin + path, {
      method: body ? "POST" : "GET",
      credentials: "include",
      headers: body ? { "Content-Type": "application/json" } : {},
      body: body ? JSON.stringify(body) : undefined,
    });
  }

  form.addEventListener("submit", function (ev) {
    ev.preventDefault();
    var q = question.value.trim();
    if (!q || !me) return;
    if (needCheck() && !token) { say("Please wait for the check to finish, then press Ask again."); return; }
    var turn = history.concat([{ role: "user", content: q }]);
    add("You", "sb-you", q);
    question.value = "";
    ask.disabled = true;
    say("Thinking. This can take a few seconds.");
    call("/chat", { messages: turn, turnstile: token }).then(function (r) {
      return r.json().then(function (data) { return { status: r.status, data: data }; });
    }).then(function (r) {
      ask.disabled = false;
      if (r.status === 200) {
        history = turn.concat([{ role: "assistant", content: r.data.answer }]);
        add(me.siteName, "sb-bot", r.data.answer);
        me.checked = true;
        if (r.data.remaining !== null) me.remaining = r.data.remaining;
        clearCheck();
        say(remainingText());
        if (!me.signedIn && me.remaining === 0) showSignin(true);
      } else if (r.status === 429) {
        me.remaining = 0;
        say("");
        showSignin(true);
      } else if (r.status === 403) {
        say("The check did not pass. Try again.");
        clearCheck();
        renderCheck();
      } else {
        say("Sorry, no answer came back. Try again in a moment.");
      }
      question.focus();
    }).catch(function () {
      ask.disabled = false;
      say("Sorry, no answer came back. Try again in a moment.");
    });
  });

  emailForm.addEventListener("submit", function (ev) {
    ev.preventDefault();
    emailButton.disabled = true;
    call("/signin/email", { email: email.value.trim() }).then(function (r) {
      emailButton.disabled = false;
      say(r.status === 200 ? "Sent. Open the link in the email to sign in; it works for 15 minutes." : "That did not send. Check the address and try again.");
    }).catch(function () {
      emailButton.disabled = false;
      say("That did not send. Try again in a moment.");
    });
  });

  call("/me").then(function (r) { return r.json(); }).then(function (data) {
    me = data;
    safety.textContent = me.safetyLine;
    say(remainingText());
    if (!me.signedIn && me.remaining === 0) showSignin(true); else showSignin(false);
    renderCheck();
  }).catch(function () {
    say("The question box is not available just now.");
    ask.disabled = true;
  });
})();
