# Help&I

**A call-for-help unit for elderly and vulnerable people that keeps working when the power, the
phone lines and the internet do not.**

Status: **pre-alpha, design stage.** Nothing here is ready to rely on.

> Help&I supplements 999, NHS 111 and any existing telecare service. It never replaces them.
> In an emergency, call 999 first if you can.

## Why

The UK's move from analogue landlines to digital (VoIP) means many telecare pendant alarms now
depend on mains power and broadband. In a power cut they can stop working, and mobile coverage
often fails within hours as mast batteries run down. That is exactly when vulnerable people most
need to ask for help.

Help&I gives each household a small unit with three buttons. It sends a request to local
volunteer wardens over whichever route still works, falling back to a licence-free LoRa mesh
that needs no mains, no internet and no mobile network.

## The unit

| Button | Size | Meaning |
|---|---|---|
| Red | Large | Come now |
| Amber | Small | Come when convenient |
| Green | Small | I'm OK now |

The unit also:

- detects mains loss and, if the user opted in, tells the wardens the power is down;
- reports its own battery at an estimated 24, 12, 6, 3, 2 and 1 hours remaining, until a warden
  acknowledges the power cut, after which only the final warning is sent;
- shows a clear cross if a message could not be delivered, so the user knows they were not
  heard, not ignored. There is no "delivered" tick, so nobody mistakes delivery for help on
  the way.

An optional companion pendant with a charging cradle covers falls away from the unit. An
optional phone and Apple Watch app adds preset requests (Can't get up, Need medical assistance,
Need food, Need a chat, Power cut) and free text. The unit's buttons always work without it.

## Wardens

Wardens receive loud audio alerts, acknowledge every request **by hand** (help is never
confirmed automatically) and can reply. An unacknowledged request escalates to the next warden.
During a widespread outage wardens see one summary ("14 units on battery, lowest 6 h"), not a
flood of separate alarms.

## How messages travel

The unit picks the first route that works:

1. Internet (home Wi-Fi)
2. Mobile network (multi-network SIM)
3. [MeshCore](https://github.com/meshcore-dev/MeshCore) LoRa mesh at 868 MHz, licence-exempt,
   with solar-powered repeaters

The phone app talks to the unit over Bluetooth, with Wi-Fi as a fallback when available.

## Privacy

Messages carry a unit number, never a name, address or medical detail. Mesh traffic uses a
private, encrypted channel. Each household signs a consent sheet that says what is sent and who
can see it.

## Hardware

Prototypes use Heltec WiFi LoRa 32 (v3/v4) boards running MeshCore-based firmware. Finished units
sold to others will need UKCA/RED conformity before release.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). AI agents: read [AGENTS.md](AGENTS.md).

## Licence

AGPL-3.0 ([LICENSE](LICENSE)). Contributions are also covered by the andeye Contributor Licence
Agreement ([CLA.md](CLA.md)).

Help&I is an andeye Ltd project. Website: https://help.andeye.com
