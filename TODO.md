# TODO

## Open

### Decisions for Martin

- [ ] **If the first coordinator is lost.** Only the group's first coordinator can remove people or make coordinators, so two coordinators can never split the group onto different keys. If that phone is lost, nobody can remove it. Should another coordinator be able to take over (say, with a second coordinator's confirmation), or should the group be started again?
- [ ] **Buttons on a plain Heltec.** Standard MeshCore companion firmware has no red, amber or green button behaviour: a Heltec v4 has one user button (PRG) and no buzzer, and the companion firmware only relays what the phone app sends. So the prototype is app-driven, and "the buttons work alone" (AGENTS.md) needs either Help&I firmware on the board or buttons wired to it, which decision 8 currently rules out. Which?
- [ ] **Signing.** The app is built unsigned for the simulator. Running it on real phones needs an Apple team in Xcode on MBP08L (claude account) and a bundle ID prefix; `com.andeye.help` is used for now.
- [ ] **MeshCore data_type.** Help&I frames use `0xFF48` from MeshCore's testing range, which needs no registration. Register a permanent value in MeshCore's `docs/number_allocations.md` before release?
- [ ] **Critical Alerts entitlement.** Apply once enrolment moves to andeye Ltd (see the app spec).
- [ ] **Apple account holder before anyone else installs it.** The Apple Developer Program License Agreement (13 Oct 2026, section 10) makes the account holder indemnify Apple, including for apps whose failure "could lead to death, personal injury". Today that is the individual membership, so you personally. Convert to andeye Ltd before TestFlight or the App Store; testing on your own phones is fine meanwhile.
- [ ] **Position sharing and App Review.** The same agreement (3.3.3 F(i)) says apps using location APIs "may not be designed or marketed ... for emergency or life-saving purposes"; F(vi) allows letting users "share their location with others they explicitly approve". Help&I's position sharing is the caller choosing to send it to their group, so describe it that way in the app and the App Store listing, never as an emergency location feature. Confirm before submission.
- [ ] **SMS route on iPhone.** The agreement now has a Critical Messaging API (3.3.8 G): SMS "for critical situations", by entitlement. It could bring back the iPhone SMS route left out of the first attempt. Apply for it alongside Critical Alerts once the account is andeye Ltd?
- [ ] **Pro relay provider and price** (app spec open question).
- [ ] **Simulator on the build Mac.** Xcode 27.1 on MBP08L reports "CoreSimulator is out of date", so the app builds but cannot run in the simulator. An admin needs to open Xcode once there (or run `sudo xcodebuild -runFirstLaunch`) to install its components. Until then nothing can be checked by eye, so screenshots and UI tests are blocked.
- [ ] **Relay name and deployment.** The relay Worker is called `helprelayandeye` to follow the `<x>andeye` rule without a hyphen. Is that the name you want? Deploying it needs your Cloudflare account: `cd relay && npx wrangler deploy`, then enter its https address in the app under Group, Internet route.
- [ ] **Push notifications.** Built and tested, off until you add an APNs key: in Apple Developer, Certificates, Identifiers and Profiles, Keys, make a key with Apple Push Notifications service, then `cd relay && npx wrangler secret put APNS_KEY` (paste the .p8 contents), and the same for `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_TOPIC` (`com.andeye.help`). The app also needs signing with the Push Notifications capability. Until then the internet route reaches a phone only while the app is open; the mesh route works in the background.

## Open (work)

- [ ] **Watch straight to the box** - not built: watchOS reportedly offers only Pair or Dismiss for a Bluetooth accessory, with no way to type the box's six-digit code, which MeshCore's companion firmware needs. Waiting on Martin trying it (Help&I-fromClaude T1). Out of reach of its phone, the watch uses its own internet only.
- [ ] **Positions as a change, confirmed by responders** - the rest of decision 12: a position sent as the change from the last one each responder confirmed receiving, or in full when that is smaller or unknown, with a small signed receipt from each responder for positions only. The responders' key and the single sealed message are done.
- [ ] **One box for a household** - MeshCore's companion firmware takes one Bluetooth connection at a time, so each phone needs its own box. Sharing one box needs Help&I's own firmware (see Buttons on a plain Heltec) or a shared hub.
- [ ] **Responders in more than one group** - Martin, 2026-10-28: "It would be useful if responders at least could be members of multiple groups."
- [ ] **A default relay** - once a relay is deployed, new groups could use it without the coordinator entering an address.
- [ ] Name callers in pushes: built (`app/helpandeyeNotify`), but needs signing with a shared keychain group. Set `HelpAKeychainGroup` in both Info.plist sections of `app/project.yml` to `$(AppIdentifierPrefix)com.andeye.help.shared`, and add the matching keychain-access-groups entitlement to both targets.
- [ ] Battery and power-cut reports from the box (decisions 3 and 4).
