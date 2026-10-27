# Changelog

Done work, newest first. Open items live in the issue tracker.

## 2026-10-27

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
