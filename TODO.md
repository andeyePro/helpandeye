# TODO

## Open

### Decisions for Martin

- [ ] **Buttons on a plain Heltec.** Standard MeshCore companion firmware has no red, amber or green button behaviour: a Heltec v4 has one user button (PRG) and no buzzer, and the companion firmware only relays what the phone app sends. So the prototype is app-driven, and "the buttons work alone" (AGENTS.md) needs either Help&I firmware on the board or buttons wired to it, which decision 8 currently rules out. Which?
- [ ] **Signing.** The app is built unsigned for the simulator. Running it on real phones needs an Apple team in Xcode on MBP08L (claude account) and a bundle ID prefix; `org.andeye.helpandi` is used for now.
- [ ] **MeshCore data_type.** Help&I frames use `0xFF48` from MeshCore's testing range, which needs no registration. Register a permanent value in MeshCore's `docs/number_allocations.md` before release?
- [ ] **Critical Alerts entitlement.** Apply once enrolment moves to andeye Ltd (see the app spec).
- [ ] **Pro relay provider and price** (app spec open question).
- [ ] **Simulator on the build Mac.** Xcode 27.1 on MBP08L reports "CoreSimulator is out of date", so the app builds but cannot run in the simulator. An admin needs to open Xcode once there (or run `sudo xcodebuild -runFirstLaunch`) to install its components. Until then nothing can be checked by eye, so screenshots and UI tests are blocked.
- [ ] **Relay name and deployment.** The relay Worker is called `helprelayandeye` to follow the `<x>andeye` rule without a hyphen. Is that the name you want? Deploying it needs your Cloudflare account: `cd relay && npx wrangler deploy`, then enter its https address in the app under Group, Internet route.
- [ ] **Push notifications.** Built and tested, off until you add an APNs key: in Apple Developer, Certificates, Identifiers and Profiles, Keys, make a key with Apple Push Notifications service, then `cd relay && npx wrangler secret put APNS_KEY` (paste the .p8 contents), and the same for `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_TOPIC` (`org.andeye.helpandi`). The app also needs signing with the Push Notifications capability. Until then the internet route reaches a phone only while the app is open; the mesh route works in the background.

## Open (work)

- [ ] Caller's typed text and position over the mesh as direct messages to each responder's board (decision 12). They go over the internet already. Needs each member's board public key in the group, and adding responders' boards as MeshCore contacts.
- [ ] Battery and power-cut reports from the box (decisions 3 and 4).
- [ ] Sign availability and notice-acknowledgement frames as acknowledgements are, so a removed phone cannot fake them during the seven-day changeover. Today they are accepted only from current member numbers.
- [ ] Share check-in schedules over the mesh too, or in key updates, so responders without internet also watch them.
