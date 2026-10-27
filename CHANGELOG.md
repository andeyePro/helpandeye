# Changelog

Done work, newest first. Open items live in the issue tracker.

## 2026-10-27

- [x] **Calls repeat until acknowledged** - an independent planning pass found that a call went out
  once per route, so one lost radio packet meant nobody was ever alerted. The latest call is now
  sent again after 30 seconds, 1, 2 and 4 minutes, then every 10 minutes, on every route, until a
  responder's signed acknowledgement arrives; it never stops on a timer. Resends count as optional
  airtime, so they can never use up the allowance a new press needs. A responder who has
  acknowledged and hears the call again sends the acknowledgement again, so a lost ack is
  repaired. Each responder's alert now repeats (every minute for red, five for amber) from their
  turn until someone acknowledges, and is topped up while the app runs. 73 core tests; manual
  checks 15 and 16.
- [x] **Typed messages and location over the internet** - after a call, the caller can type a short
  message (up to 120 bytes) and share where they are, once, when they choose. Both are sealed with
  the group key and go only over the internet route; `HelpFrame.mayGoOnGroupChannel` keeps them off
  the shared radio channel, and the board refuses them (decision 12). Responders see the message and
  a Maps link with its accuracy. 66 core tests; manual check 14.
- [x] **Fixes from the first code review** - a press with no route available now gives the cross at
  once instead of "Sending…" for ever. Acknowledgements are signed with the responder's own key and
  checked against the current member list, so a removed or lost phone, or another member, cannot
  falsely reassure a caller, and old channel keys stop working seven days after a removal. Request
  numbers live in the keychain with the group so they never restart after a reinstall, and stale
  acks from before a request was made are ignored. Open requests, the rota and who answered last
  are saved, so they survive the app closing, and escalation turns are counted from when the caller
  pressed. The box shows Connected only when the group's channel is on it; message pushes are no
  longer lost while syncing; calls for help jump the command queue; a timed-out command reconnects
  instead of risking a late reply being taken for the next; reconnects back off; stale channel
  slots are reused; Forget this box no longer leaves "Connecting…". Airtime is reserved before each
  send and the budget is kept across reconnects, so overlapping sends cannot exceed the duty cycle.
  Follow-ups, availability and notice acks go over the mesh only if the internet did not take them.
  A responder whose acknowledgement did not go out is told and can retry. The model and watch link
  start at launch, so a watch press works with the phone app closed. Keychain writes no longer
  delete before adding. Check-ins are wired in: reminders at the set times, and a missed one sends
  an amber call. 61 core tests; four new manual checks (10 to 13).
- [x] **Check-in schedule logic** - `CheckIn.swift` works out when an opt-in check-in was missed:
  agreed times with a grace window, a green press only counting inside its window, nothing missed
  before the schedule started, and times kept on the wall clock across the October and March clock
  changes (a test caught 09:00 turning into 08:00 on 25 October). Wiring it into the app follows.
- [x] **Internet route through a relay** - `relay/` is a Cloudflare Worker (free tier, one SQLite
  Durable Object per group) that stores and forwards messages sealed on the phones with the group
  key, so it holds ciphertext and public keys only. Every request is signed with the phone's
  Ed25519 key and must be fresh; only a coordinator can set the member list, a removed phone is
  refused at once, and messages are kept a week at most. A meter warns, on every response, once 80%
  of Cloudflare's free daily allowance is used. The app seals, signs, posts and polls every 10
  seconds while open, and shows coordinators a notice that widens to everyone until someone
  acknowledges it; rota gaps raise the same notice. Tests: 6 for the relay (`npm test`, including
  one that checks the relay verifies a request signed by the app) and 49 in HelpAndICore. Not yet
  done: push notifications to wake phones, so the internet route only reaches a phone while the
  app is open.
- [x] **First iOS and watchOS app** - `app/` builds an unsigned iOS app with an embedded watch app
  (XcodeGen, Xcode 27.1). Callers get the three buttons, a status card that never implies help is
  coming before a responder acknowledges, a cross with reasons when nothing was sent, follow-up
  details, and a ready-written text offered only when every other route failed. Responders get a
  list that never closes by itself, an Acknowledge button, and alerts scheduled at their turn in
  the escalation, so they fire in the background. Groups are started and joined with three QR
  codes, lost phones removed with new keys handed out as update codes. The box tab pairs a Heltec
  on MeshCore companion firmware over Bluetooth, writes the group's private channel into it, and
  refuses to send on a frequency outside the UK bands. The watch sends through the phone.
  `tests/MANUAL-TESTS.md` has nine hardware checks. The internet route is not built yet.
- [x] **Group keys and joining in person** - `Group.swift` in HelpAndICore makes each group's
  secrets at random, joins a member with three QR codes and no network (the group sealed to the
  new phone's key with X25519 and ChaCha20-Poly1305), gives both phones a six-digit safety number
  for joining at a distance, and rotates the secrets when a phone is removed without ever reusing
  its unit number. 7 new tests, 42 in all.
- [x] **HelpAndICore Swift package** - `app/HelpAndICore` holds the app's logic with no UI, tested
  by 35 tests (`swift test` on macOS): the 12-byte Help&I frame on the MeshCore group channel (data
  type `0xFF48`), caller status with no "delivered" state and the cross only when every route
  failed, the responder inbox that dedupes across routes and never closes or acknowledges by
  itself, escalation that only widens (2 min red, 15 min amber), closest-then-fairest ordering, the
  rota with gap detection and coordinator alerts, IR 2030 duty-cycle budgeting, iPhone SMS left out
  of the first attempt, and the MeshCore companion protocol frames the app needs.
- [x] **Keys, lost phones and rota gaps decided for now** - `docs/app-spec.md` settles its three
  open questions with common practice: per-phone keys that never leave the phone, group secrets
  made by the coordinator's app and shared by QR or a verified link, relays that hold public keys
  only, key rotation when a phone is removed, and rota gaps worked out on every phone and sent
  over the mesh without names. `TODO.md` lists the decisions only Martin can make.
- [x] **Caller's text and position may go over the mesh** - decision 12, AGENTS, CONTRIBUTING,
  README and the app spec now allow short typed text and the caller's position on air, as
  encrypted direct messages to each responder after the call for help, when airtime allows. Calls
  for help and the group channel still carry a unit number only. The spec also alerts the
  coordinator, then the responders, before the free relay allowance runs out.
- [x] **Every route at once; free and Pro tiers** - red and amber now go over every automatic route
  at once instead of the first that works (decision 8, README). `docs/app-spec.md` confirms the
  escalation times, leaves iPhone SMS out of the first attempt, and adds a free tier that costs
  andeye nothing and a Pro tier whose fees cover its second relay.
- [x] **Draft app specification** - `docs/app-spec.md` sets the first release's scope: iOS and
  watchOS, one app for callers and responders, coordinator-run groups with availability, fair
  sharing and closest-first alerting, peer-to-peer groups, and red or amber sent at once with
  details following as separate messages. The internet relay design and every-route sending are
  marked as proposals.
- [x] **Linkable decisions** - each row of `docs/design-decisions.md` has an anchor (`#d10`), and
  Claude's Discussion answers link every decision and open question they cite.
- [x] **Fuller Discussion answers** - Claude now answers with its own expertise and web search, not
  only the project documents, on Opus with up to about 400 words. It still marks what is decided,
  what is open and what is its own suggestion. Tools are limited to WebSearch and WebFetch, so the
  thread still cannot reach a shell or files on the runner.
- [x] **Discussion replies come from github-actions[bot]** - Anthropic's app-token exchange answers
  `Invalid OIDC token` to any workflow but its own action, which does not handle Discussions, so
  replies cannot appear as the Claude app. They are now posted with the workflow's own token and
  open with "**Claude** (Anthropic's AI assistant):".

## 2026-10-26

- [x] **@claude in Discussions** - `.github/workflows/claude-discussions.yml` answers any discussion or
  comment that mentions @claude, posting as the Claude GitHub App. Claude runs with no tools, sees
  only the project documents and the thread, and answers only questions about Help&I. Runs on the
  maintainer's Claude subscription through the `CLAUDE_CODE_OAUTH_TOKEN` secret.
- [x] **Safety green and a first-aid cross** - the mark moves from Material green 800 to safety green
  `#009A44` and from a thin plus to a square-ended Greek cross of five equal squares (ISO 7010 E003),
  regenerated from `assets/brand/gen_mark.py` with the site icons. The site marks every claim that
  needs a local radio network with an asterisk explained in a closing "Be clear what you have"
  section, opens each situation for more detail, uses one text width throughout, and carries the
  same four buttons top and bottom.
- [x] **Site adopts andeye kit v1** - dark kit tokens, type, layout, hero and eyebrow mark sizes, and the
  standard footer, with the Help&I mark inline from `assets/brand/gen_mark.py`. Adds favicon, Apple
  touch icon and Open Graph image. Deployed as the Cloudflare Worker `helpandeye` from `wrangler.jsonc`.
- [x] **Positioned by situation, not by person; wardens renamed responders** - README, CONTRIBUTING
  and AGENTS now describe a resilient call-for-help system for neighbourhoods, people out on their
  own, community groups and teams, with the phone app first and the box and pendant optional.
  Added the opt-in check-in schedule, the intent to design to BS 8484 and BS 9518 with the mesh
  as an addition to them, and the intent to seek wearable fall-detection entitlements. Decisions
  15 to 18 in `docs/design-decisions.md`. Site lede and meta description brought into line.
