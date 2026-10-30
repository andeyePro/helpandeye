# Site bot

A chat bot that answers visitors' questions about one website, from that site's own content, on
a Cloudflare Worker. It was built for help.andeye.com and is written to be lifted out as its own
project: nothing outside `config.js` names the site.

What a visitor gets:

- Two free answers a day, after a Cloudflare Turnstile check that they are a person. The free
  answers are counted by a salted hash of their address, kept for 24 hours and then forgotten.
  The salt changes daily, so the hash can never be matched back to an address.
- After that, sign in with an emailed link or with GitHub, and ask as much as they like. Nothing
  about a signed-in visitor is stored: the session is a signed cookie, their id is a GitHub
  number or a hash of their email address, and their questions are not kept.
- Answers from Claude, which is given the site's content and told to answer only from it, to
  point elsewhere for anything it does not cover, and never to say that help is coming. The
  site's safety line (for Help&I: "Help&I does not replace 999 or telecare. In an emergency,
  call 999 first if you can.") is shown above the questions and repeated by the model whenever
  anyone asks about an emergency.

What the site owner gets:

- A cost estimate for every answer, from its token counts at the model's list price
  (`src/prices.js`), summed over a rolling six hours for everyone together and for each visitor
  (signed-in id, or address hash while anonymous).
- An email when everyone together has cost more than 2% of the month's credit in any six hours,
  or any one visitor more than 1%. Each is sent at most once every six hours. There are no
  other limits: the alert is for the owner to act on.

## The model

The default is Claude Haiku 5.5 (`claude-haiku-5-5`): the bot answers from a short, fixed text,
which is a lookup rather than a reasoning task, and Haiku is twenty times cheaper than Sonnet
for the same tokens, with the site content cached between questions. At Anthropic's list prices
a typical answer (about 5,000 prompt tokens, mostly cached, and 150 output tokens) costs well
under a tenth of a cent. The `MODEL` var changes it; `src/prices.js` must know the model's
price, or it is costed at the dearest price in the table.

## Add it to a site

1. Edit `config.js`: the site's name and address, the safety line, where to send questions the
   content does not answer, and the content itself as plain text. The model answers only from
   that text, so keep it in step with the site.
2. Deploy the Worker on a subdomain of the site, for example `bot.example.com` for
   `example.com`, so that its session cookie is first-party in every browser.
3. Put one element and one script tag on the page:

   ```html
   <div id="site-bot"></div>
   <script src="https://bot.example.com/widget.js" defer></script>
   ```

   `data-container="#other"` on the script tag uses another element. The widget takes its
   colours from the page's CSS variables (`--text`, `--panel`, `--accent`, `--line`, `--muted`
   and so on) where the page has them, and has plain defaults where it does not. It loads
   Turnstile's script from `challenges.cloudflare.com`; a Content-Security-Policy on the page
   must allow that, and `connect-src` to the bot's origin.

The widget is keyboard-only usable, labels every field, announces answers and status to screen
readers, uses no animation, and scales with the page's text size.

## Secrets and vars

Secrets, set with `npx wrangler secret put <name>`:

| Secret | What |
|---|---|
| `ANTHROPIC_API_KEY` | An API key from the bot's own workspace (below) |
| `SESSION_SECRET` | A long random string (`openssl rand -base64 48`). Signs session cookies, sign-in links and the address hash. Changing it signs everyone out. |
| `TURNSTILE_SECRET_KEY` | From the Turnstile widget in the Cloudflare dashboard |
| `GITHUB_CLIENT_SECRET` | From the GitHub OAuth app (below). Leave unset to offer no GitHub sign-in. |

Vars, in `wrangler.jsonc`:

| Var | What |
|---|---|
| `TURNSTILE_SITE_KEY` | The widget's public key, from the same Turnstile widget. Add the site's hostname to the widget's domains. |
| `GITHUB_CLIENT_ID` | From the GitHub OAuth app. Empty for no GitHub sign-in. |
| `EMAIL_FROM` | The address sign-in links and alerts come from. Its domain must be enabled for Cloudflare Email Sending (below). Empty for no email sign-in and no alerts. |
| `EMAIL_FROM_NAME` | The sender's name ("Site bot" if empty) |
| `ALERT_EMAIL` | Where the spend alerts go. Empty for none. |
| `MONTHLY_CREDIT_USD` | The month's credit in dollars that the 2% and 1% alerts are shares of (200 if empty) |
| `MODEL` | The Claude model (`claude-haiku-5-5` if empty) |
| `FREE_ANSWERS_A_DAY` | Free answers an address gets a day (2 if empty) |

## Setting up

**Anthropic.** In the Console, make a workspace of its own for the bot (Settings, Workspaces),
give it a monthly spend limit equal to `MONTHLY_CREDIT_USD`, and make the API key inside that
workspace. The limit is the hard stop; the bot's alerts are the early warning. The Console's
usage page shows the real spend; the bot's figures are estimates from token counts.

**Turnstile.** In the Cloudflare dashboard, Turnstile, add a widget (managed mode) for the
site's hostname. Its site key is `TURNSTILE_SITE_KEY`; its secret key is `TURNSTILE_SECRET_KEY`.

**Email.** Enable Cloudflare Email Sending for the sending domain:
`npx wrangler email sending enable example.com`. The `send_email` binding in `wrangler.jsonc`
is then live, and `EMAIL_FROM` can be any address at that domain.

**GitHub.** In GitHub, Settings, Developer settings, OAuth Apps, make an app whose callback URL
is `https://bot.example.com/signin/github/callback`. Its client id is `GITHUB_CLIENT_ID`; make a
client secret for `GITHUB_CLIENT_SECRET`. The bot asks for no scopes and reads only the user's
numeric id.

**Deploy.**

```
npm install
npx wrangler deploy
```

Then open the site and ask something. `npx wrangler tail` shows what the Worker logs, which is
only failures (an email that did not send, spend that could not be recorded).

## Run the tests

```
npm test
```

The tests run on Node with `node --test`. They never reach Anthropic, Turnstile or GitHub: fetch
is replaced with fakes that answer for them, and the clock is set by hand for the six-hour
windows.

## What is stored, and for how long

| What | Where | For |
|---|---|---|
| A salted hash of an anonymous visitor's address, with a count | The Worker's Durable Object | 24 hours from their first question of the day |
| Each visitor's estimated spend, in ten-minute buckets | The Durable Object | 6 hours and 10 minutes |
| When each alert was last sent | The Durable Object | 6 hours |
| The session cookie: signed, with an id (`github:<number>` or `email:<hash>`), or just "checked" | The visitor's browser | 30 days signed in; 24 hours anonymous |

Questions and answers are sent to Anthropic to be answered and are not kept by the bot. Email
addresses are used to send one link and are hashed before they go anywhere else.

## Licence

AGPL-3.0, like the Help&I project it was written in (see `LICENSE`).
