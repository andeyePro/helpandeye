# Design decisions

Decisions taken so far, with the reason for each. Add to this file rather than reopening a
decision silently.

| # | Decision | Reason |
|---|---|---|
| 1 | Three physical buttons: large red (come now), small amber (come when convenient), small green (I'm OK now) | Core function must work without a phone, app or charger |
| 2 | Mains-powered unit with battery backup; optional pendant with charging cradle | A fall away from the unit is the main gap a fixed unit cannot cover |
| 3 | Automatic power-cut detection; optional (opt-in) message to responders when mains is lost | Power cut plus a fall is double jeopardy; responders need early warning |
| 4 | Battery alerts at an estimated 24, 12, 6, 3, 2 and 1 h remaining; a responder's acknowledgement silences all but the final warning | Avoids alert floods once responders know the power is down |
| 5 | Responders see an aggregated outage summary | A wide outage fires every unit at once |
| 6 | Help is confirmed only by a responder's manual acknowledgement, with escalation if none | Keeps a human in the loop |
| 7 | The user sees a cross on delivery failure and no "delivered" tick | A tick could be misread as help on the way |
| 8 | Route order: internet, then multi-network mobile, then MeshCore LoRa mesh | Cheapest working route first; mesh survives multi-day outages |
| 9 | Phone link: Bluetooth, with Wi-Fi as backup when available | Bluetooth links drop; the buttons never depend on either |
| 10 | MeshCore over Meshtastic | Better routing with fixed repeaters; matches the Irvine Valley backbone. Firmware is open source; the official MeshCore phone apps are not, and are too complex for this user group, so Help&I has its own app |
| 11 | No PMR446 / dPMR446 for the home unit | PMR446 is licence-exempt only on a mobile basis; a fixed home unit is not |
| 12 | Private, encrypted mesh channel; unit numbers, never names or medical detail, on air | Health data is special-category data under UK GDPR. Encryption is permitted for licence-exempt 868 MHz use (the amateur-licence ban does not apply) |
| 13 | Device and app state plainly that Help&I supplements 999 and telecare | Duty of care and liability |
| 14 | AGPL-3.0 plus andeye CLA | Open source, with relicensing for App Store builds |
| 15 | Positioned by situation, not by person: neighbourhoods, people out on their own, community groups, teams. Button labels, responders and check-ins are set per deployment | Many people who would benefit reject anything sold as "for the elderly or vulnerable". The elderly were the design driver, not the limit |
| 16 | Opt-in check-in schedule: a missed green press raises an amber request to the responders; off by default | Lone-worker and living-alone use. It creates a request; it never acknowledges, closes or times one out |
| 17 | Design to BS 8484 (lone worker services) and BS 9518 (alarm receiving centres) wherever they apply, and seek certification. The mesh route is additional to the standards, not a substitute for them | Employers and councils buy against these standards. The mesh exists for outages in which an alarm receiving centre cannot be reached, which the standards do not cover |
| 18 | Seek the entitlements to receive fall-detection events from Apple Watch and other wearables, and pass them to responders | A detected fall is the clearest case of someone unable to press a button |

## Open questions

- Whether MeshCore companion firmware supports the Wi-Fi link and acknowledgement behaviour
  needed, or needs a fork.
- Pendant radio link to the unit (LoRa, or a simpler short-range link).
- Which BS 8484 and BS 9518 clauses the volunteer-responder model cannot meet, and whether a partner alarm receiving centre is needed for certified deployments.
- Fall detection: Apple's CMFallDetectionManager needs an entitlement granted on application by the Account Holder, and the system's own fall alert still fires first. Apply once the watch app exists. Whether Google or Samsung expose the same on Wear OS is unchecked.
- UKCA/RED conformity route for sold units, product liability insurance, and how the TSA telecare
  quality framework applies.
