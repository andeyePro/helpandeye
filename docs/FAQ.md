# Developer FAQ

Questions people building Help&I ask. Questions about using it are answered on the website, at
https://help.andeye.com/#faq. If yours is not here, ask in
[Discussions](https://github.com/andeyePro/helpandeye/discussions).

## Where do I start?

Read [CONTRIBUTING.md](../CONTRIBUTING.md), then [prototype-status.md](prototype-status.md) for
what works and what is next. Open work is in [TODO.md](../TODO.md). Open an issue before a large
change.

## What hardware do I need?

For the app: a Mac with Xcode, and an iPhone (an Apple Watch is optional). For the box: a Heltec
WiFi LoRa 32 V3 or V4 running MeshCore's standard companion firmware, with nothing added
([decision 8](design-decisions.md#d8)). Most of the app's logic runs and is tested without either.

## How do I build it and run the tests?

```
cd app && xcodegen generate && open helpandeye.xcodeproj
cd app/helpandeyeCore && swift test
cd relay && npm test
```

Checks that need real phones and boards are in [tests/MANUAL-TESTS.md](../tests/MANUAL-TESTS.md).

## Why MeshCore and not Meshtastic?

Better routing with fixed repeaters ([decision 10](design-decisions.md#d10)). The MeshCore phone
apps are not open source and are too complex for the people Help&I is for, so it has its own app.

## Why not PMR446 for the home unit?

PMR446 is licence-exempt only on a mobile basis, and a home unit is fixed
([decision 11](design-decisions.md#d11)).

## Why is there no SIM in the box?

The phone goes out with the user, the box stays at home, and the phone already has a SIM
([decision 8](design-decisions.md#d8)). A SIM in the box may come later.

## Why no "delivered" tick?

A tick could be read as "help is on the way". The caller sees a cross when delivery fails, and is
told help is coming only when a person acknowledges ([decisions 6 and 7](design-decisions.md#d6)).

## Is encryption allowed on 868 MHz?

Yes, for licence-exempt use; the ban on encryption applies to amateur licences
([decision 12](design-decisions.md#d12)).

## Can I work on Android?

Yes, please. There is no Android app yet. The rules the app follows are in
`app/helpandeyeCore`, and [docs/app-spec.md](app-spec.md) describes what it does.

## Why do I have to sign a CLA?

The code is AGPL-3.0. The CLA also licenses contributions to andeye Ltd, so that it can relicense
them for App Store builds ([decision 14](design-decisions.md#d14)). See [CLA.md](../CLA.md).

## Can I use an AI coding agent?

Yes. You must understand what you submit and be able to answer for it in review, and changes to
how a unit behaves need your own run on real hardware. Agents read [AGENTS.md](../AGENTS.md).

## How does @claude in Discussions work?

Mention @claude in a discussion and Claude, Anthropic's AI assistant, replies there. It answers
only questions about Help&I. Where this FAQ, the website's FAQ, a decision or an earlier
discussion already covers part of a question, it links that and adds what is new.
