# Help&I

**Resilient call-for-help system.** Press a button and reach people who know you, over whatever
still works: the internet, your mobile network, another mobile network, or a local radio mesh
that needs no mains electricity, no internet and no licence.

Status: **pre-alpha, design stage.** Nothing here is ready to rely on.

> Help&I supplements 999, NHS 111, telecare services and any lone-working procedure you already
> have. It never replaces them. In an emergency, call 999 first if you can.

## Who it is for

Help&I is a resilient call-for-help system that can be configured for different situations:

- **Neighbourhoods** where someone wants a neighbour, a relative or a local volunteer to know when
  something is wrong, including people whose telecare alarm stops working in a power cut.
- **People out on their own**: lone workers, farmers, walkers and field staff, who want a
  check-in and a help button that work where there is no signal.
- **Community groups** running a local network for their street, village or valley during an
  outage, with volunteers answering.
- **Teams** at a site or an event who need a simple way to call for a hand.

The people who answer are called responders. They can be family, neighbours, a volunteer rota or a
works team. Who answers, what the buttons mean and whether check-ins are on are all set when a
system is provisioned.

## Why

The UK's move from analogue landlines to digital (VoIP) means many telecare pendant alarms now
depend on mains power and broadband. In a power cut they can stop working, and mobile coverage
often fails within hours as mast batteries run down. Away from home the problem is simpler:
large parts of the country have no usable signal at all. Either way, the moment someone most
needs to ask for help is the moment the usual routes fail.

## Two halves

**Phone and optional wearable.** A phone app and an optional watch app which can call for help
using preset message buttons or free text. They talk to a button box over Bluetooth, or send
directly when the phone has a route. The watch app adds a help button on your wrist; it does not
replace the watch's own fall detection or emergency calling. We intend to apply for the
entitlements that let the app receive fall-detection events from Apple Watch and other wearables,
so that a detected fall can reach responders too.

**Optional box and pendant.** A mains-powered button box with a battery, an optional pendant
with a charging cradle for incidents away from the box, and mesh repeaters on mains power with
battery and optional solar backup. The
buttons work with no phone, no app and no charger.

## Simple buttons

| Button | Size | Meaning |
|---|---|---|
| Red | Large | Come now |
| Amber | Small | Come when convenient |
| Green | Small | I'm OK now |

The labels can be changed per deployment (for a works team, green might be "Checked in"). The
shape, size and colour stay the same so that nobody has to learn a new layout.

These may be the only buttons you need on the pendant, and they are mirrored in the app, but
after sending the initial call for help, the app can give follow-up buttons to give responders a
better picture of the issue.

## Responders

Responders receive loud audio alerts, acknowledge every request **by hand** (help is never
confirmed automatically) and can reply. An unacknowledged request escalates to the next responder.
During a widespread outage responders see one summary ("14 units on battery, lowest 6 h"), not a
flood of separate alarms.

## How messages travel

The box is a standard Heltec LoRa board with nothing added. It sends over the
[MeshCore](https://github.com/meshcore-dev/MeshCore) LoRa mesh at 868 MHz, licence-exempt, with
repeaters on mains power with battery and optional solar backup. It reaches the internet and the
mobile networks only through the phone app, over Bluetooth, because the phone goes out with the user
and the box stays at home. A call for help goes out at once over every route that works:

1. Internet, through the phone
2. The phone's own mobile network
3. Other mobile networks, if the phone has a multi-network SIM
4. The MeshCore mesh, where the community has built one

## Privacy

A call for help carries a unit number, never a name, address or medical detail. Mesh traffic
uses a private, encrypted channel. Anything the caller types, and their position, goes only to
each responder directly, encrypted. Each user signs a consent sheet that says what is sent and who can
see it.

## Standards

Help&I is being designed to meet BS 8484 (lone worker services) and BS 9518 (alarm receiving
centres) wherever they apply, so that it can be certified. It is not certified today, and nothing
here may be read as if it were. The mesh route sits outside what those standards cover: it exists
for the outages in which an alarm receiving centre cannot be reached at all.

## Hardware

Hardware units also:

- detect mains loss and, if the user opted in, tell the responders the power is down;
- report their own battery at an estimated 24, 12, 6, 3, 2 and 1 hours remaining, until a responder
  acknowledges the power cut, after which only the final warning is sent;
- show a clear cross if a message could not be delivered, so the user knows they were not
  heard, not ignored. There is no "delivered" tick, so nobody mistakes "message sent" for
  "message received and understood, help is on the way";
- can run an opt-in **check-in schedule**: the user presses green at agreed times, and a missed
  check-in raises an amber request to the responders. It is off unless the user turns it on.

Prototypes use Heltec WiFi LoRa 32 (v3/v4) boards running MeshCore-based firmware. Finished units
sold to others will need UKCA/RED conformity before release.

## Where help is wanted

- **Phone and watch apps**: iOS and watchOS first, Android to follow. An Android developer would
  move that forward.
- **Firmware**: buttons, battery and mains sensing, message format, escalation.
- **Radio and mesh**: repeater siting, range testing, staying within Ofcom limits.
- **Responder console**: the view the people who answer actually use.
- **Testing with real users**: running the steps in `tests/MANUAL-TESTS.md` on real boards and
  phones, and telling us what confused you.

## App

`app/` holds the iOS and watchOS app (SwiftUI) and `app/HelpAndICore`, a Swift package with all of
its logic and tests. The Xcode project is generated from `app/project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
cd app && xcodegen generate && open HelpAndI.xcodeproj
cd app/HelpAndICore && swift test
```

The app talks over Bluetooth to a Heltec board running MeshCore's standard companion firmware.
`tests/MANUAL-TESTS.md` lists the checks that need real phones and boards.

## Website

`site/` is plain HTML with no build step. Cloudflare serves it as a Worker with static assets,
configured in `wrangler.jsonc` and built from this repository by Workers Builds: `main` is
https://help.andeye.com, `dev` is https://dev.help.andeye.com, and every other branch gets a
preview URL on `workers.dev`. Change the site on a branch, merge to `dev` to review it, then merge
`dev` to `main` to go live.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). AI agents: read [AGENTS.md](AGENTS.md).
Questions are welcome in [Discussions](https://github.com/andeyePro/helpandeye/discussions); mention
@claude there for an answer from Claude, Anthropic's AI assistant.

## Licence

AGPL-3.0 ([LICENSE](LICENSE)). Contributions are also covered by the andeye Contributor Licence
Agreement ([CLA.md](CLA.md)).

Help&I is an andeye Ltd project. Website: https://help.andeye.com
