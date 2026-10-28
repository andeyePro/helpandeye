# Changelog

Done work, newest first. Open items live in the issue tracker.

## 2026-10-28

- [x] **Core for one box serving several groups** - the first part of responders in more than one group: `MeshHub` gives each group's engine its own view of one shared box (`SharedBox`), which listens on every group's channels, sends each frame only on its own group's, and hands what it hears on a group's channel to that group's engine only. The groups' engines share one hour's radio allowance (`AirtimeLedger`), so together they stay inside the band's duty cycle (IR 2030). Not yet: the app (the box link, storage per group, joining a second group, a merged Respond list). 191 core tests pass.
- [x] **Group settings reach every member at once** - a coordinator's Advanced settings (the words on the buttons, the escalation times and the relay's address) now go to every member as soon as they change, and again daily with the member list, as a new signed frame (`groupSettings`, the first of a second page of frame kinds, header 0x21) over the internet and, when it fits, the group channel. Only a coordinator's signature counts, and an older version heard late changes nothing back. 189 core tests pass.
- [x] **Accessibility audit: real failures only, and fixes** - the screen test now keeps Apple's clipped-text and partial Dynamic Type findings, and contrast read through the see-through title and tab bars, as advice to check on the screenshots (they are known to flag SwiftUI text that fits and grows), and fails on the rest. The paste box is labelled above instead of by a faint placeholder, and the joining and inviting sheets have a Close button (on iPad, and with VoiceOver, a sheet is not always easy to swipe away). On the small and large iPhone the remaining findings are text scrolled to the screen's edge; the iPad's are elements of a sheet no longer shown, fixed by the Close button.
- [x] **Sealed notes and positions are signed by the caller, and survive a changeover** - a review of the responders' key found that any responder could work out the sealing key and so write a note or position as a caller, and that during the seven-day changeover after a removal, responders who had not yet scanned their update could not read anything sealed with the new key. Now the caller signs what goes inside (checked against the member whose unit it names), it is sealed once for each responders' key in use during a changeover, only keys still in use are tried when opening, and long typed text goes as several notes broken between words, each fitting one 165-byte MeshCore datagram with the signature. A note on role changes records why no one can gain or lose the responders' key that way. 187 core tests pass.
- [x] **Welcome codes about half the length** - a welcome or key update now seals the group compressed and writes the code as binary (`HELPA2:`) instead of JSON whose keys were already base64, then base64 again: under 1,000 characters for a small group instead of about 1,700, so its QR code is less dense and quicker to scan. Welcomes made by an earlier build still open. 183 core tests pass.
- [x] **Personal content goes once, sealed for responders (decision 12)** - each group now has a responders' key pair: every member holds the public half, only responders the private half (a caller's welcome and key updates leave it out). What a caller types, and their position, are sealed once with a key made from the caller's own key and the responders' public key, and sent once, over the internet or else as one message on the group channel, instead of one text-encoded direct message to each responder's box. On air it adds only the clear unit, request and part, a 5-byte nonce salt and the 16-byte tag (29 bytes; the longest note still fits one 165-byte MeshCore datagram); with five responders that is one transmission instead of five. Another caller cannot read it, and its outside cannot be moved to another call. Groups made before this keep the direct messages. Not yet: positions sent as a change from the last one each responder confirmed (the rest of decision 12). 182 core tests pass.
- [x] **Watch fixes from review** - a review of the watch work found that one press could send two calls, that the watch could keep acting after its owner left, and that alerts could be muted when only the watch had heard a call. Now: the watch makes the call itself and gives the same call to the phone, which sends it on its own routes under the watch's number (`adopt`), so it is always one call; the phone tells the watch to forget everything when its owner leaves the group; the watch stays quiet only for calls its phone has heard, and alerts held back are let go as one alert now, not a burst (`Alert.fromNow`); an acknowledgement from the watch says if it could not go out; a fresh handover keeps the watch's call numbering; the handover goes as a one-off transfer only when it changes, not in the always-kept context; the watch ignores other members' boxes. 181 core tests pass; phone and watch build. Manual check 7 rewritten.
- [x] **The relay can wake the watch** - each member can now register a watch push token beside their phone's (`device: "watch"`), and the relay wakes watches quietly, at the watch app's own topic, even for a call: the watch fetches what is waiting and alerts its wearer itself, and only while their phone is out of reach, so one call never shows twice. A member's own phone and watch are never woken by their own call, and both tokens go when the member is removed. The watch registers for pushes at launch. 22 relay tests pass; phone and watch build. Needs the APNs key and signing to try on a real watch.
- [x] **The watch works without the phone** - the phone now hands its paired watch the group and its owner's keys (`WatchHandover`), and the watch runs its own engine in a new companion mode: when the phone is out of reach it calls over the watch's own Wi-Fi or mobile internet and responds as the same member, with its calls numbered 32768 and up so they never clash with the phone's, and leaves the member list, check-ins and rota gaps to the phone. With the phone in reach the buttons still go through the phone. The watch's own alerts are held back while the phone is in reach, so one call never buzzes twice. The watch shows the group's button words, readable colours, and a plain cross and "use your phone or call 999" when neither phone nor internet can be reached. Not yet: the watch has no box of its own (Bluetooth straight to the box) and no push, so out of reach it hears calls only while the app is open. 179 core tests pass; phone and watch build. Manual check 7 extended. No watch simulator is available yet, so the watch screens have not been screenshotted or audited.
- [x] **Joining fixed up, coordinator chooses roles, button words editable, Come now at the bottom** - from Martin's tries at joining between his iPhone and Mac. The coordinator now picks what a new member will do (call for help, respond, or both) before the invitation is shown; the invitation carries it and the coordinator's phone enforces it, whatever the request says. Codes pasted from a message are read even with words around them or broken across lines, and a wrong code is named (the invitation again, a member's code, a welcome, or an older version's code) instead of a bare "not a code". The joiner's place in the three steps, and their name and number, are kept if they leave the screen, with a Start again button. Coordinators get Advanced settings with the internet route and the words on every button (decision 15; members get new words when they next join or scan a key update). The Help screen puts Come now at the bottom, below the other two, nearest the thumb. 174 core tests pass.

## 2026-10-27

- [ ] **Accessibility audit in progress** - a UI test (`app/helpandeyeUITests`) now walks every screen a new coordinator sees, saves a screenshot of each and runs Apple's accessibility audit; `tests/screens.sh` runs it on a small and a large iPhone and an iPad, in light and dark mode, at the normal and the largest text size. Fixed from its first findings: buttons and headings were below contrast (new action blue at 6.5:1, links a lighter blue in dark mode, warnings in a darker red, call buttons darkened, amber with black words), greyed-out buttons replaced by ones that say what is missing, text boxes labelled above the box and for VoiceOver, the status card made solid. Still open: remaining contrast and Dynamic Type findings on the Help, Group and Box screens.
- [x] **Easier to read, type and undo** - from Martin's first use on his iPhone. The keyboard can always be put away (Done above it, scrolling, or tapping an empty part of the Help screen), and the Help screen scrolls. Small grey text is gone: everything uses at least the body size in the normal colour, and Group has a Text size choice (as set for the phone, Larger, Largest) on top of the phone's own setting. Call categories such as I'm locked out are now ticked when chosen and untick when pressed again; taking one back sends a `withdrawn` follow-up in the same part, and a copy of the original heard late does not bring it back. Something else opens the message box (the keyboard's microphone takes speech), and when typed messages cannot be sent the screen says why instead of hiding the box. Share where I am is a full button, and a caller can choose to send where they are with every red or amber call. The app now runs on iPad, and so on Apple silicon Macs. 171 core tests pass; the app builds and launches in the simulator. Manual check 33 added.
- [x] **Mobile numbers for the text fallback** - Martin found the ready-written text could open with no recipient, because a coordinator had nowhere to enter a number. Now the coordinator can give one when starting a group, every member can change theirs under Group, Your mobile number, and the coordinator's member list shows responders with no number. A change goes to the group as a new signed frame (`memberPhone`, kind 15), over the internet only, never on the radio (decision 12); only the member or a coordinator can set it, and an older change heard late is ignored. Numbers are kept on each phone, so the text itself needs no internet. Send as a text goes to every other responder with a number, and is not offered when there is none. Core tests added for the frame, the recipients and the engine rules: 170 core tests pass and the iPhone build succeeds.
- [x] **Signing team survives regenerating the project** - `app/Signing.xcconfig` turns on automatic signing and includes an optional, git-ignored `app/Local.xcconfig` holding the developer's own `DEVELOPMENT_TEAM`, so `xcodegen generate` no longer wipes the team chosen in Xcode. Device build succeeds.
- [x] **Internal names drop HelpAndI** - Swift types, Info.plist keys, relay headers, signing labels, QR prefix and test settings now use `HelpA`/`HELPA` (for example `HELPA-GROUP-1`, `X-HelpA-Key`, `HELPA1:`), so nothing internal spells andi, andeye or &I. Signatures and group IDs change, so the relay test vectors were regenerated from the app; nothing was deployed, so no live group is affected. The QR prefix length is no longer hard-coded. 165 core tests, 20 relay tests, device build succeeds.
- [x] **The app follows the andeye naming** - the Xcode project, targets, folders and Swift package are now `helpandeye`, `helpandeyeNotify`, `helpandeyeWatch` and `helpandeyeCore`, and the bundle IDs `com.andeye.help` (plus `.notify` and `.watchkitapp`), in line with `com.andeye.money`. The app is still shown as Help&I. 165 core tests, 20 relay tests, device build succeeds.
- [x] **Three small fixes to reading the relay** - a narrow review of the relay-reading change found
  nothing that loses or falsely confirms a call, and three small issues, now fixed with tests:
  after a relay reset, the fifteen-minute first-read rule now applies, so old calls are not
  alerted as new; a relay that gives no log name is no longer taken as reset; a place saved by an
  earlier version is kept; and a page thinned by expired messages no longer stops a read early.
  165 core tests.
- [x] **Reading the relay, and the caller's words, are tested** - how a phone reads the group's
  messages from the relay is now `RelayPoll` in HelpAndICore, with seven tests: a first read hears
  calls still open (every open call is resent more often than the fifteen-minute window it uses)
  and not a week of old ones; a backlog longer than a page is read through without skipping; expired
  messages never stall the place; and a relay that was reset is noticed even if it has refilled
  past the phone's place, which before would have skipped those messages for good (the relay now
  names its log, and the name changes if it is reset). What the caller is told on phone and watch
  is now `StatusWords`, with tests that only an acknowledgement is ever put as seen, nothing else
  reassures, and the cross and 999 appear whenever nothing was sent. 161 core tests, 20 relay tests.
- [x] **Fixes from the seventh code review, on the radio path** - a seventh independent review, of the
  path a press takes to the radio, found 1 blocker and 6 major issues. Fixed: looking for boxes
  while one was connected stopped calls going out and incoming ones being fetched until the app
  restarted (looking is now separate from the link, and stops after twenty seconds); a box that
  ran out of channel slots during a changeover never recovered, and joining a group during the
  handshake left the box unusable (setup now re-runs whenever the keys change with the link up, one
  run at a time, and readiness is worked out afresh each time; the slot logic is `ChannelPlan` in
  HelpAndICore, tested, including a full box recovering); after a drop the app now reconnects at
  once, which iOS honours while suspended, with a pause only after failures; the link is rebuilt
  after the system relaunches the app and dropped when Bluetooth is switched off; the box's code is
  shown before pairing, from the keychain; a send's channels are taken before anything is awaited,
  so the airtime counted is what went on air; a box already connected when you join a group is
  announced at once; a wrong pairing code now drops the link so it tries again; a failed write is
  reported at once as never written; and a slot is listened on as soon as it is set up. Answers to
  new boxes held back by the one-a-minute limit now go when the minute is up, rather than being
  lost. 152 core tests; manual checks 28 to 32.
- [x] **The Bluetooth command queue is tested** - the queue that puts a call on the radio lived in
  the app, where no machine test ran it. It is now `CommandQueue` in HelpAndICore, with six tests:
  nothing is written before the link is up, one command at a time, a call for help goes ahead of
  waiting setup, a push is never taken for a reply, a timeout stops all writing so a late reply
  cannot be taken for the next command, and a dropped link answers everything once. Moving it
  found an old under-count: a send that timed out was reported as certainly not sent, so its
  airtime was given back although the packet may have gone on air; only a command never written
  counts as not sent now. 147 core tests.
- [x] **Fixes from the sixth code review** - a sixth independent review of the relay's new
  membership rules and of invitee confirmation found 1 blocker and 4 major issues. Fixed: a removal
  made within a minute of another publish could miss the relay for a day (a changed member list
  now goes at once, and only the list actually sent counts as published); the relay's owner could
  be whoever registered first and removals then silently did nothing (a group's ID is now made from
  its first coordinator's key, so only a list naming them can register it); people added by a
  removed coordinator that the first coordinator never knew stayed on the relay for good (they now
  go with that coordinator); the member list had no size limit and accepted any string as a key
  (now 256 members and real keys only); a delayed older list from the owner could undo a role
  change; a refused list was retried every minute (now not until it changes; unreachable relays
  back off); the confirming repeat needed a box (now runs from every tick); the timeout and the
  "inviter left" cases have their own wording; and the first coordinator lists anyone it hears
  another coordinator add straight away, so they are confirmed without waiting a day. The Swift
  copy of the relay rules follows all of this and is checked against the relay both by recorded
  fuzz runs and by the same hand-written cases. 141 core tests, 19 relay tests; 200 fuzz seeds pass.
- [x] **An unconfirmed invitation is said plainly** - someone invited by a second coordinator who was
  removed before the first coordinator heard of the invitation used to believe they were in the
  group while nobody else knew. Their phone now counts itself confirmed only once it hears the
  first coordinator list it (the first coordinator repeats the list daily). If that has not happened
  within two days, or it hears its inviter was removed, it shows a notice asking them to check with
  another coordinator. The fuzz test checks every such phone is told. 134 core tests; manual check
  27.
- [x] **The fuzz test uses the relay's real membership rules** - the fake relay used to deliver to
  everyone, so the relay's refusals never happened in the fuzz. It now follows a Swift copy of the
  relay's rules, checked against the real relay by replaying member-list publishes recorded from
  fuzz runs (`relay/test/model.test.js`). With that, it found three real bugs: a first
  coordinator's list removed anyone it had not yet heard of, for good, so someone a second
  coordinator invited could be banned from the relay; a second coordinator who registered the
  group first became its owner, so the first coordinator's removals were then ignored and removed
  phones stayed on the relay; and when that happened everyone was registered as a plain member.
  Membership on the relay is now a union: lists add people, only removals the first coordinator
  names take anyone off, the list names the first coordinator as owner, and roles come as listed at
  registration and from the owner after. A coordinator's phone now retries publishing the member
  list a minute after a failure and repeats it daily. After links heal, the fuzz test checks that
  the relay lists everyone the phones agree on and nobody removed. 132 core tests, 16 relay tests;
  200 fuzz seeds pass.
- [x] **Fixes from the fifth code review, and named pushes** - a fifth independent review found 1
  blocker and 7 major issues, and the strengthened fuzz test found two more. Fixed: a second
  coordinator had no way to scan new keys after a removal, so a week later their calls reached
  nobody; a key update replaced each phone's member list with the first coordinator's, erasing
  people a second coordinator had added (it now merges membership and takes only the keys); the
  relay could let a removed member back in through a same-version merge, and let any coordinator
  take people off (now only the first coordinator can, removed keys can never be listed again,
  and duplicate keys are refused); saved activity, requests and check-ins missing a newer field
  were thrown away whole (all now load with defaults); key updates are accepted only from the first
  coordinator; an old signed check-in schedule, replayed, no longer replaces a newer one; a caller
  whose acknowledgement is taken back is told plainly; a newcomer answers boxes at most once a
  minute; the box's Bluetooth code is sent only once safely saved and shown only once the box took
  it. The fuzz test now also has second coordinators inviting, forged removals and role changes,
  key updates, the app being closed and reopened, and after links heal checks that every open call
  is with every responder, still alerting and still being sent, and that all phones are on the same
  keys. A notification extension now opens the sealed call a push carries and names the caller
  (needs signing; TODO.md). 132 core tests, 17 relay tests; 300 fuzz seeds pass; manual checks 24
  to 26.
- [x] **A fuzz test of the safety rules** - `EngineFuzzTests` runs groups of four to six phones
  through 250 random steps per seed: presses, acknowledgements, retries, availability, promotions
  and removals, links going up and down, lost packets, clock jumps of up to a day, typed messages,
  positions and check-ins, while removed phones keep acknowledging and replaying captured signed
  messages. After every step it checks that every acknowledgement anywhere is one a person made
  (or, on a phone not yet told of a removal, from that removed member), that every open call keeps
  alerting each responder who heard it, that nothing personal goes on the group channel and no
  direct message goes to a box the sender does not list, that numbers and units never clash, that
  airtime stays within the limit, and that all phones agree on the members once links heal. 60
  seeds run in `swift test` (`HELPANDI_FUZZ_SEEDS` for more; 400 pass). It was checked by planting
  two bugs, both caught at once. It found one real gap: an acknowledgement from a member who is
  later removed went on reassuring the caller after the phone heard of the removal. Now it is taken
  back: the caller sees "waiting" again, the call is resent, and responders are alerted again. 126
  core tests.
- [x] **Fixes from the fourth code review** - a fourth independent review of the multi-coordinator,
  check-in, Bluetooth-code and watch changes found 1 blocker and 7 major issues. Two coordinators
  out of touch could hand out the same number block, or each remove someone and split the group
  onto different keys, after which a red call reached only half the responders: now only the
  group's first coordinator removes people or makes coordinators (other coordinators invite), and
  blocks are never reused. Groups saved by earlier versions load again instead of being silently
  lost. The box's new Bluetooth code is saved before it is sent and always shown in the Box tab, and
  is set only on boxes without a screen (MeshCore's firmware shows a random code on screened boxes
  such as the Heltec V3 and V4). Only responders can be made coordinators, so a caller who cannot
  come out is never sent alerts. Removals are repeated with the member list, so a phone that missed
  one catches up. A removed caller's check-ins stop being watched. Check-ins over the internet are
  signed by the caller. A phone that hears a new box answers with its own, so late joiners learn
  everyone's box. The watch is told whether an acknowledgement was really made. The relay accepts a
  merged member list at the same version if it keeps everyone. 124 core tests, 15 relay tests.
- [x] **More than one coordinator** - a coordinator can now make someone else a coordinator, so a
  group does not depend on one person. The change goes to every phone in a signed role-change
  message carrying the membership version, so an old one replayed cannot undo a newer one. Every
  membership message now carries the version, so all phones agree on it and either coordinator's
  member list is accepted by the relay, and carries the member's sealing key, so a second
  coordinator can hand out key updates. Each coordinator gives out member and unit numbers from
  their own block of 1,000, so two coordinators adding people while out of touch never clash. 117
  core tests, including one where the second coordinator adds and removes people and everyone
  follows.
- [x] **Large text and VoiceOver** - a pass over every screen's words found them plain and calm, with
  no "delivered" wording and the 999 notice in place. Fixed: the Come now button and the watch's
  999 line used fixed sizes that ignored the reader's text size; at large sizes the amber and green
  buttons now stack instead of squeezing; each call button says what it does to VoiceOver; and the
  caller's status is spoken aloud when it changes, including when a responder has seen the call.
  Manual check 22.
- [x] **A random Bluetooth code on every box** - MeshCore's default pairing code, 123456, is the same on
  every box. The app now reads the box's code and, if it is the default, sets a random six-digit
  one with the firmware's set-PIN command (37, found in MeshCore's source) and shows it once to
  write down. Manual check 2 covers it.
- [x] **How to bring up the hardware** - `tests/MANUAL-TESTS.md` now opens with what to flash (MeshCore
  Companion (BLE) firmware, from MeshCore's web flasher), radio settings, the default Bluetooth
  PIN and why to change it, building and signing the app, how to record a run, and the order to run
  the checks in. Firmware facts are from MeshCore's own README and FAQ. The app does not yet set a
  random Bluetooth PIN as the spec says; that is now in TODO.md.
- [x] **Check-ins reach responders with no internet** - a caller's check-in schedule went to
  responders over the internet only, so in a mesh-only group, the power-cut case Help&I exists for,
  responders never knew it and could not notice a missed check-in. It now also goes as a MeshCore
  direct message to each responder's box, never on the group channel, is sent to any box the caller
  hears for the first time, and is repeated once a day. A schedule counts only if it came from the
  caller's own box. 115 core tests (two new end-to-end); manual check 21.
- [x] **Fixes from the third code review** - a third independent review, which ran the tests, found
  1 blocker and 9 major issues. Fixed, each with a test: a removed phone could replay its old
  coordinator-signed "member added" during the changeover and get its acknowledgements counted
  again (member numbers are now never reused and a removed one can never be re-added); a removed
  member's box key, rota entries and answering record are forgotten, so nothing private goes to
  their box; "I'm OK now" alerts once and no longer counts as open, so many greens cannot squeeze a
  red call down to three alerts; a call that first reaches the relay on a resend asks for a push;
  membership messages that change nothing no longer reconfigure the relay and box on every phone,
  and the coordinator repeats the member list at most once a day; leaving and rejoining keeps the
  airtime record and the mesh route; every signature now covers the group's ID; direct messages
  check the frequency band; a removed caller's press shows the cross; unacknowledged calls survive
  the 50-request cap; acks heard before a call are checked once it arrives; late results of an
  earlier ack attempt are ignored; calls may use only 90% of the legal duty cycle, leaving room for
  the firmware's own traffic; a send counts as sent if either channel took it. New members' names
  follow over the internet. Relay: a cursor that moves past expired messages, a first read that
  hears calls still open, 20 posts and 2 pushes per phone per minute, one push per call during a
  changeover, slower polling when nothing is open, deleted push tokens for removed members, and a
  shown error if the member list is refused. The contrived second-coordinator test is replaced and
  multiple coordinators are marked not built (TODO.md). Responders can also acknowledge from their
  watch. 113 core tests, 14 relay tests; manual check 20.
- [x] **The rules move into a tested engine** - about 560 lines of untested app logic (which acks
  count, when alerts start and stop, resends, re-acks, the personal-content guard, airtime) are now
  `HelpEngine` in HelpAndICore, behind small interfaces for the box, relay, alerts, storage and
  clock; the app plugs in the real ones and the tests plug in fakes. Twelve end-to-end tests run a
  coordinator, a caller and a responder over a fake radio and relay: a press reaches responders and
  only a human ack shows "seen"; a lost first packet is repaired by a resend; forged and removed
  acks never reassure; no route gives the cross at once; nothing closes and alerts never stop
  without a human, over thirty simulated days; an ack cancels alerts everywhere; re-acks are rate
  limited; personal content never goes on the group channel; direct messages from the wrong box
  are ignored; resends never take the airtime a new press needs; members who have not updated still
  hear during a changeover; and a second coordinator takes the first one's membership changes,
  which it did not before. The internet-only path, with its push requests, is tested too. 104
  tests. Manual checks 1 to 19 need running again on hardware at this commit.
- [x] **Everyone hears who joined or left** - adding someone used to change only the coordinator's
  copy of the group, so a caller's phone would reject a new responder's acknowledgement and never
  show "seen". A coordinator's phone now sends a signed member-added or member-removed frame over
  the internet and the mesh, repeats who is in the group when its box connects, and other phones
  apply it at once (names follow in a key update). During the seven-day changeover after a removal,
  phones send on both the old and new channel and keys, so members who have not scanned their
  update still hear calls and acknowledgements; the relay refuses the removed phone, and the
  airtime budget counts both packets. 92 core tests; manual check 19.
- [x] **Signed availability and notice acknowledgements** - both now count only inside a frame signed
  by the member they are about, so a removed phone that still knows the old channel key cannot
  take responders off the rota (delaying their alerts) or clear a coordinator's notice. 91 core
  tests.
- [x] **Typed messages and location over the radio** - with no internet, a caller's typed message
  (cut to 96 bytes) and position now go as MeshCore direct messages to each responder's box, which
  MeshCore encrypts to that box alone, never on the group channel (decision 12). Each phone tells
  the group its box's public key in a frame signed by the member's own key, so nobody can redirect
  a member's private messages, and adds the other boxes as contacts. A direct message counts only
  if it came from the box of the member whose unit it names. Sent only within the optional half of
  the airtime allowance. 89 core tests.
- [x] **Push notifications from the relay** - phones register their APNs token with the relay
  (per member, dropped with the member). A call's first send asks the relay for a visible,
  time-sensitive push to every other member that names nobody, since the relay cannot read who
  called; an acknowledgement asks for a silent push that only wakes the caller's app. A push makes
  the app fetch from the relay and schedule its own alerts. The provider token is an ES256 JWT made
  in the Worker. Off until the APNs secrets are set (TODO.md). 12 relay tests.
- [x] **Fixes from the second code review** - a second independent review of the send, alert and
  relay code found 17 issues. Fixed: the relay read position was shared by all groups, so a
  responder who changed group could silently miss every internet-route call (now per group and
  relay, and a first read starts from the latest instead of replaying a week as new alerts).
  Membership has its own version, so an out-of-date coordinator's phone cannot drop a newer member
  from the relay, and a refused poll is shown. Every unacknowledged call is resent, not only the
  latest, and a missed check-in is not raised while a red or amber call is waiting. After a long
  sleep, missed resend slots are skipped rather than sent back to back. A timed-out box command now
  stops all writes until a fresh handshake, so a late reply cannot mark a call as sent, and airtime
  is given back only when the box certainly did not transmit; the airtime log is saved across
  relaunches and re-pairing. Responder alerts have a long tail (red: every minute for ten minutes,
  then every ten minutes; amber every five, then every thirty) so they last hours with the app
  asleep; "I'm OK now" alerts once, quietly, and is repeated only four times. The same numbers
  pressed at a different time are a new call; responders ignore acks from before a call, like the
  caller. Any phone holding a signed ack passes it on when it hears the call repeated. Messages
  waiting on the box are not drained before the channel is known; a box that never answers shows
  its failure instead of "Connecting…" and backs off. Availability and notice acks count only from
  current members, and the old channel is dropped when the changeover ends. Relay: one storage key
  per message, 512-character limit, allowance warning at the Durable Object limit, 30-second polls.
  Responders' phones now also watch callers' check-ins (shared over the internet only) and raise a
  missed one if the caller's phone did not. 86 core tests, 7 relay tests; manual checks 16 to 18.
- [x] **Calls repeat until acknowledged** - an independent planning pass found that a call went out
  once per route, so one lost radio packet meant nobody was ever alerted. The latest call is now
  sent again after 30 seconds, 1, 2 and 4 minutes, then every 10 minutes, on every route, until a
  responder's signed acknowledgement arrives; it never stops on a timer. Resends count as optional
  airtime, so they can never use up the allowance a new press needs. A responder who has
  acknowledged and hears the call again sends the acknowledgement again, so a lost ack is
  repaired. Each responder's alert now repeats (every minute for red, five for amber) from their
  turn until someone acknowledges, and is topped up while the app runs. 73 core tests; manual
  checks 15 and 16.
- [x] **Typed messages and location over the internet** - after a call, the caller can type a short
  message (up to 120 bytes) and share where they are, once, when they choose. Both are sealed with
  the group key and go only over the internet route; `HelpFrame.mayGoOnGroupChannel` keeps them off
  the shared radio channel, and the board refuses them (decision 12). Responders see the message and
  a Maps link with its accuracy. 66 core tests; manual check 14.
- [x] **Fixes from the first code review** - a press with no route available now gives the cross at
  once instead of "Sending…" for ever. Acknowledgements are signed with the responder's own key and
  checked against the current member list, so a removed or lost phone, or another member, cannot
  falsely reassure a caller, and old channel keys stop working seven days after a removal. Request
  numbers live in the keychain with the group so they never restart after a reinstall, and stale
  acks from before a request was made are ignored. Open requests, the rota and who answered last
  are saved, so they survive the app closing, and escalation turns are counted from when the caller
  pressed. The box shows Connected only when the group's channel is on it; message pushes are no
  longer lost while syncing; calls for help jump the command queue; a timed-out command reconnects
  instead of risking a late reply being taken for the next; reconnects back off; stale channel
  slots are reused; Forget this box no longer leaves "Connecting…". Airtime is reserved before each
  send and the budget is kept across reconnects, so overlapping sends cannot exceed the duty cycle.
  Follow-ups, availability and notice acks go over the mesh only if the internet did not take them.
  A responder whose acknowledgement did not go out is told and can retry. The model and watch link
  start at launch, so a watch press works with the phone app closed. Keychain writes no longer
  delete before adding. Check-ins are wired in: reminders at the set times, and a missed one sends
  an amber call. 61 core tests; four new manual checks (10 to 13).
- [x] **Check-in schedule logic** - `CheckIn.swift` works out when an opt-in check-in was missed:
  agreed times with a grace window, a green press only counting inside its window, nothing missed
  before the schedule started, and times kept on the wall clock across the October and March clock
  changes (a test caught 09:00 turning into 08:00 on 25 October). Wiring it into the app follows.
- [x] **Internet route through a relay** - `relay/` is a Cloudflare Worker (free tier, one SQLite
  Durable Object per group) that stores and forwards messages sealed on the phones with the group
  key, so it holds ciphertext and public keys only. Every request is signed with the phone's
  Ed25519 key and must be fresh; only a coordinator can set the member list, a removed phone is
  refused at once, and messages are kept a week at most. A meter warns, on every response, once 80%
  of Cloudflare's free daily allowance is used. The app seals, signs, posts and polls every 10
  seconds while open, and shows coordinators a notice that widens to everyone until someone
  acknowledges it; rota gaps raise the same notice. Tests: 6 for the relay (`npm test`, including
  one that checks the relay verifies a request signed by the app) and 49 in HelpAndICore. Not yet
  done: push notifications to wake phones, so the internet route only reaches a phone while the
  app is open.
- [x] **First iOS and watchOS app** - `app/` builds an unsigned iOS app with an embedded watch app
  (XcodeGen, Xcode 27.1). Callers get the three buttons, a status card that never implies help is
  coming before a responder acknowledges, a cross with reasons when nothing was sent, follow-up
  details, and a ready-written text offered only when every other route failed. Responders get a
  list that never closes by itself, an Acknowledge button, and alerts scheduled at their turn in
  the escalation, so they fire in the background. Groups are started and joined with three QR
  codes, lost phones removed with new keys handed out as update codes. The box tab pairs a Heltec
  on MeshCore companion firmware over Bluetooth, writes the group's private channel into it, and
  refuses to send on a frequency outside the UK bands. The watch sends through the phone.
  `tests/MANUAL-TESTS.md` has nine hardware checks. The internet route is not built yet.
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
