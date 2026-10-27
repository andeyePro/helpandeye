# Contributing to Help&I

Thanks for looking. Help&I lets people call for help, and check in, when power, phones and
internet are down. Someone may depend on it on the worst day of their year, and that shapes most
of what follows.

## The short version

- Open an issue before a large change, so nobody builds the same thing twice.
- Every change to user-facing behaviour comes with a test in the same commit.
- Add your name to `CONTRIBUTORS.md` in your first pull request, in your own commit.
- Everything you contribute is released under AGPL-3.0 and, separately, licensed to andeye Ltd
  under `CLA.md`. Both are explained under **Licensing** below.

## What the project will and will not take

### A human confirms help

A request is only answered when a responder acknowledges it by hand. Changes that confirm, close
or time out a request automatically will not be accepted.

### Supplement, never replace

Help&I adds to 999, NHS 111, telecare and any lone-working procedure already in place. It does
not replace them, and its copy must say so.

### Privacy

Units are identified by number. Names, addresses and medical details are never sent over the
air. The one exception is what the caller chooses to send: short text they typed and their
position, sent as encrypted direct messages to each responder after the call for help itself.

### Radio

Help&I uses licence-exempt 868 MHz LoRa and must stay within Ofcom IR 2030 limits for power and
duty cycle in every region it ships for.

### Calm and clear

User-facing copy is short, plain and kind, written for people who may have poor sight, hearing
or memory. It explains what to do; it does not dramatise why. Help&I is non-political.

### AI-generated code

You may use whatever tools you like. What matters is that you understand what you are submitting
and can answer questions about it in review. Agents: see `AGENTS.md`.

## Tests

| What changed | Where the test goes |
|---|---|
| Firmware logic (message format, alerts, escalation) | Unit tests alongside the code |
| Anything needing eyes, ears or hands (buttons, buzzers, range, battery) | `tests/MANUAL-TESTS.md` |

A test that passes because it does not know about your change is not coverage. If something
genuinely cannot be tested, add it to `MANUAL-TESTS.md` and say so in the pull request.

## House style

- British spelling in prose and user-facing copy.
- Comments explain **why**, not what.
- No em dashes in user-facing copy.

## Licensing: what you are agreeing to

Help&I is licensed under **AGPL-3.0** (`LICENSE`).

Contributions are additionally covered by the **andeye Contributor Licence Agreement** (`CLA.md`,
version 1.0). In plain terms: you keep your copyright, your contribution stays available under
AGPL-3.0 and that cannot be taken back, and you additionally allow andeye Ltd to relicense it
(for example so the app can ship through the App Store, which cannot distribute AGPL software).
The numbered clauses in `CLA.md` are what actually binds.

The CLA Assistant check runs on every pull request and will ask you to agree once.
