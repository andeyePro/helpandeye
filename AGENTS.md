# AGENTS.md

Instructions for an AI coding agent asked to work on Help&I. If you are a human contributor,
read `CONTRIBUTING.md` instead.

Help&I is a call-for-help unit for elderly and vulnerable people: firmware for Heltec LoRa boards,
a responder console, an optional phone and watch app, and the help.andeye.com site. Someone may
press its red button while lying on the floor in a power cut. Much of what it does (buttons,
buzzers, radio range, battery life) cannot be checked by a machine. That is the constraint
everything below follows from: for changes that affect behaviour on a unit, the project's final
quality gate is a contributor who has run the change on real hardware and can answer for every
line of it.

## Process

`CONTRIBUTING.md` is the authority on what the project will take, the test rule, house style and
licensing. Read it and follow it. Do not restate it here or in a PR body. Every PR is checked
against the CLA (`CLA.md`); your user agrees to it, not you.

## Verification, and reporting it

Before you hand anything over, run every check a machine can run, and say which ones exist and
which do not yet. The test rule in `CONTRIBUTING.md` is not optional: a change to behaviour comes
with its test in the same commit, and a test that passes because it does not know about the
change is not coverage. If the behaviour can only be checked by eyes, ears or hands, the test is
a new step in `tests/MANUAL-TESTS.md`, and your user runs it.

Do not open a merge-ready PR until your user has given you evidence that each relevant manual
check passed on real hardware. Their run is the last thing that happens: change a line afterwards
and it is void. Record the commit they actually ran.

Every PR description must state:

- **What changed and why:** one or two sentences, and the issue it fixes.
- **What it does:** a short bullet list of the concrete behaviour changes.
- **Developed with:** your harness, lead model and main agents.
- **Checks run:** one line per machine check, with its result.
- **What was tested:** the boards, firmware version, phones and radios used, and which
  `MANUAL-TESTS.md` sections your user ran.
- **Not tested:** state it plainly. A body that implies coverage it does not have is not.

## Rules that are easy to break

- **Help is confirmed by a human.** Only a person closes a call: the caller where their
  coordinator allows it, or a coordinator who records why (decision 6). Nothing acknowledges,
  closes or times out a call on its own.
- **No false reassurance.** Nothing may tell a user that help is coming unless a responder
  pressed acknowledge. The unit shows a cross when delivery fails. Do not add a "delivered" tick
  or any state a user could read as "someone is on their way".
- **The buttons work alone.** No core function may depend on the phone app, Bluetooth, Wi-Fi or
  the internet.
- **Supplement, never replace.** Copy, packaging and the unit itself must say that Help&I does not
  replace 999 or telecare. Do not remove or soften that wording.
- **No stored personal data on air.** Red, amber, green and anything on the group channel carry
  a unit number only: never a name, address or medical detail. The only personal content allowed
  on air is what the caller chose to send (short text they typed, a choice such as Fallen, and
  their position), sent after the red or amber has gone, sealed once for all responders with a
  key only responders hold (decision 12), and only when there is airtime to spare.
- **Stay within licence-exempt limits.** 868 MHz use must stay within Ofcom IR 2030 power and
  duty-cycle limits. No change may raise transmit power or duty cycle beyond them.
- **No shared secrets.** Never bake a password, key or token into firmware or an app build.
  Per-unit credentials are generated at provisioning.
- **Calm, not alarmist.** User-facing copy says what to do, plainly and kindly, for people who may
  have poor sight, hearing or memory.

## What gets an agent-written PR rejected

- **Noise in the diff.** No comments restating the line below, no defensive checks for
  conditions that cannot arise, no helper used once. If it is not load-bearing, delete it.
- **Anything obviously odd.** Unused variables, a pattern that appears nowhere else in the tree,
  code that does not match the surrounding file.
- **A contributor who cannot answer for the code.** Explain every change to your user in plain
  terms before the PR goes up: what it does, why, and what breaks without it. "The agent wrote
  it" is not an answer.
- **Personal or machine-specific detail.** No addresses, names of real users, LAN addresses,
  hostnames, home paths or unit IDs from a real deployment.

## If a second AI reviews the diff

A review that does not cite specific files and line numbers from the diff did not read the diff.
Discard it. Require file and line citations, check two of them against the diff, and throw the
review away if they do not match.
