# Design decisions

Decisions taken so far, with the reason for each. Add to this file rather than reopening a
decision silently.

| # | Decision | Reason |
|---|---|---|
| <a id="d1"></a>1 | Three physical buttons: large red (help), small amber (need a hand), small green (I'm OK) | Core function must work without a phone, app or charger |
| <a id="d2"></a>2 | Mains-powered unit with battery backup; optional pendant with charging cradle | A fall away from the unit is the main gap a fixed unit cannot cover |
| <a id="d3"></a>3 | Automatic power-cut detection; optional (opt-in) message to responders when mains is lost | Power cut plus a fall is double jeopardy; responders need early warning |
| <a id="d4"></a>4 | Battery alerts at an estimated 24, 12, 6, 3, 2 and 1 h remaining; a responder's acknowledgement silences all but the final warning | Avoids alert floods once responders know the power is down |
| <a id="d5"></a>5 | Responders see an aggregated outage summary | A wide outage fires every unit at once |
| <a id="d6"></a>6 | Help is confirmed only by a responder's manual acknowledgement, with escalation if none. Only a person closes a call: the caller, where their coordinator allows it, or a coordinator who records the caller's consent or a reason, such as "spoke to them on the phone, all well", in the group's log. Nothing acknowledges, closes or times out a call on its own (Martin, 2026-10-28) | Keeps a human in the loop. A call pressed by mistake, or dealt with outside Help&I, can still be closed, and the log shows who closed it and why |
| <a id="d7"></a>7 | The user sees a cross on delivery failure and no "delivered" tick | A tick could be misread as help on the way |
| <a id="d8"></a>8 | The box is a standard Heltec LoRa board (v4 or similar) with nothing added: it sends over the MeshCore LoRa mesh, and over the internet and mobile networks only through the user's phone app. Red and amber go out at once over every route that works without the caller's help: internet, the phone's own mobile network, other mobile networks (a multi-network SIM in the phone), and the mesh (Martin, 2026-10-27) | Better value in the phone, which goes out with the user, than in a box that stays at home or a pendant that gets heavier and needs charging. Mesh survives multi-day outages. A SIM in the box may come later (Martin, 2026-10-26) |
| <a id="d9"></a>9 | Phone link: Bluetooth, with Wi-Fi as backup when available | Bluetooth links drop; the buttons never depend on either |
| <a id="d10"></a>10 | MeshCore over Meshtastic | Better routing with fixed repeaters. Firmware is open source; the official MeshCore phone apps are not, and are too complex for this user group, so Help&I has its own app |
| <a id="d11"></a>11 | No PMR446 / dPMR446 for the home unit | PMR446 is licence-exempt only on a mobile basis; a fixed home unit is not |
| <a id="d12"></a>12 | Everything on the mesh is encrypted. A call for help carries a unit number; names come from each phone's own member list. What the caller types, and their position, go once to all responders, sealed with a key only responders hold. A position is sent as the change from the last one each responder has confirmed receiving, or in full when that is smaller or unknown (wording proposed by Claude; agreed by Martin, 2026-10-28) | One message for all responders uses the least airtime; callers do not hold the responders' key, so one caller cannot read another's details. Every phone already has the names. Encryption is permitted for licence-exempt 868 MHz use (the amateur-licence ban does not apply). Walkers need to say where they are |
| <a id="d13"></a>13 | Device and app state plainly that Help&I supplements 999 and telecare | Duty of care and liability |
| <a id="d14"></a>14 | AGPL-3.0 plus andeye CLA | Open source, with relicensing for App Store builds |
| <a id="d15"></a>15 | Positioned by situation, not by person: neighbourhoods, people out on their own, community groups, teams. Button labels, responders and check-ins are set per deployment | Many people who would benefit reject anything sold as "for the elderly or vulnerable". The elderly were the design driver, not the limit |
| <a id="d16"></a>16 | Opt-in check-in schedule: a missed green press raises an amber request to the responders; off by default | Lone-worker and living-alone use. It creates a request; it never acknowledges, closes or times one out |
| <a id="d17"></a>17 | Design to BS 8484 (lone worker services) and BS 9518 (alarm receiving centres) wherever they apply, and seek certification. The mesh route is additional to the standards, not a substitute for them | Employers and councils buy against these standards. The mesh exists for outages in which an alarm receiving centre cannot be reached, which the standards do not cover |
| <a id="d18"></a>18 | Seek the entitlements to receive fall-detection events from Apple Watch and other wearables, and pass them to responders | A detected fall is the clearest case of someone unable to press a button |

## Open questions

- Whether MeshCore companion firmware supports the Wi-Fi link and acknowledgement behaviour
  needed, or needs a fork.
- Pendant radio link to the unit (LoRa, or a simpler short-range link).
- Whether the box should also use the Heltec board's built-in Wi-Fi to reach the internet directly while the power and broadband are on.
- Remote areas with no mobile signal and no relay in range: satellite messaging through the phone or a device such as Garmin inReach, rather than PMR446, CB or amateur radio.
- Which BS 8484 and BS 9518 clauses the volunteer-responder model cannot meet, and whether a partner alarm receiving centre is needed for certified deployments.
- Fall detection: Apple's CMFallDetectionManager needs an entitlement granted on application by the Account Holder, and the system's own fall alert still fires first. Apply once the watch app exists. Whether Google or Samsung expose the same on Wear OS is unchecked.
- UKCA/RED conformity route for sold units, product liability insurance, and how the TSA telecare
  quality framework applies.
