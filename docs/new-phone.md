# Moving to a new phone

A design proposal, not yet built. It answers the TODO item "Moving to a new phone without iCloud
Keychain or Google backup". Decisions already taken are in
[design-decisions.md](design-decisions.md); how the app keeps its keys today is in
[app-spec.md](app-spec.md) (Keys and setting up a group) and [architecture.md](architecture.md)
(Keys).

## The decision

Martin, 2026-11-07: "'Replace this phone' isn't something that I have seen with any other app. The
normal way is you ensure iCloud has a recent backup and then you just replace your phone. You then
go into apps and do stuff after the replacement. There is a significant risk that this app isn't
particularly important to many people so they won't be thinking about it when they replace their
phone. Basically all data needs to go via iCloud, etc. so that someone can be all set up on one
phone, then replace it, wipe the old phone, sell the old phone, wait 9 months, download Help&I
again and securely restore everything 100% including their MeshCore box access."

So the design is the platform's own backup and restore: iCloud Backup and iCloud Keychain on
iPhone and Apple Watch, Google Backup and Block Store on Android. There is no step the person has
to remember, and a reinstall months after the old phone was wiped and sold restores the member in
full, box access included. The app asks at setup for the platform's backup to be on (Martin,
2026-11-02). The earlier rule that nothing built may tie the apps to Apple's or Google's services
now reads: calling for help and responding never depend on them, and backup and restore do, by
this decision. Someone with no backup comes back by the coordinator route at the end.

## What a restore must bring back

A member is their phone's key pair; the group's member list, the relay and every box hold only the
public halves. A full restore is the key pair and, for each group, the group's secrets (the channel
secret, the group key and, for a responder or coordinator, the responders' key of decision 12),
the member list, the settings, the person's own settings and check-in times, and the request
counter, so no call number is ever used twice under one unit.

Today that is all in the keychain, but marked "this device only" (`Store.write` in
`app/helpandeye/Store.swift` adds every item with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). An item in that class is left out of every
backup and never synced, which is why nothing follows a person today. The changes:

- **Class.** Add items with `kSecAttrAccessibleAfterFirstUnlock` instead. That class is included
  in an iCloud Backup and an encrypted local backup, and restored to a new phone when it is set up
  from the backup. "After first unlock" stays, because the app reads its keys in the background
  for a call.
- **Sync.** Mark the identity and the group states `kSecAttrSynchronizable`, on the add and in
  every query (`Store.query`), as iCloud Keychain carries only items marked so, and a query without
  the mark does not find them. A synchronisable item cannot use a "this device only" class, which
  is the same change as above. A synced item is also the only thing that comes back nine months
  later on a phone the app was deleted from: an iCloud Backup restores at device setup, and an app
  deleted afterwards takes its files with it, while keychain items stay on the phone through a
  deletion and synced ones arrive on any device signed in to the account.
- **What stays in files.** Open calls (`activity.json`), the radio budget (`airtime.json`) and
  the relay's read position are in Application Support, protected until first unlock and not
  excluded from backup, so an iCloud Backup made at device setup brings an open call back and the
  phone resends it; a reinstall months later does not, which is right. Two things in
  `UserDefaults` are needed to find keychain items and must move into the keychain: the tags of
  the other groups the person responds in (`Store.otherGroups`), without which their restored
  states are never looked for, and the box's pairing code, below. The box's Bluetooth identifier
  (`Store.boardID`) is different on every phone and is found again by scanning.
- **Both or neither.** `Store.identity()` makes a fresh key pair whenever none is found, so a phone
  that restored the group state without the identity would be a stranger holding a member's
  group. The identity and the states are restored by the same mechanism, and the app checks that
  the state's `me` is a member whose keys are its own before it acts; if not, it says the restore
  is incomplete rather than running as nobody.
- **The counter.** An iCloud Backup can be older than the phone's last calls, so a restored
  `lastRequest` can be behind. A responder's phone takes a repeated number as the caller still
  sending, and passes on the old acknowledgement (`Engine.swift`, `.duplicate`), which would show a
  new call as already seen. On a restore from backup the counter moves forward by a fixed jump
  (the watch already numbers its calls apart, from 32768). A state that came by keychain sync is
  current and needs no jump.
- **The relay.** The push token is the new phone's; the app registers it as it does after any
  change (`Relay.swift`, `registerPushToken`), and the relay keeps one phone token and one watch
  token per member.

### The same member on two devices

iCloud Keychain syncs to every device signed in to the account, so a member's keys can arrive on an
iPad, or on a new phone while the old one still runs. Two devices under one member would share one
request counter, each displace the other's push token, and each acknowledge as the same responder.
The proposal: each install makes a random install ID, kept device-only, and writes it into the
group state whenever it saves. A device that finds the synced state written by another install
stops acting as the member and says "Help&I is now on your other device", with a button to take
it back, which writes its own ID and makes the other go quiet in turn. So one device is the member
at a time, the newest by default, and no coordinator is involved. Whether an iPad may instead be a
second device of the same member, numbered apart as the watch is, is a question below.

### The watch

The watch keeps its owner's keys and groups in its own keychain (`Store.keep(handedOver:)`, the
same `Store.swift` built into the watch target), handed over by the phone. Its items stay "this
device only": the phone sends the handover again on every launch and whenever the groups change
(`PhoneWatchLink.handOver`, which compares with what it sent since launch, not what the watch
holds), so a new or erased watch is set up by its phone and needs no backup of its own.

### Android

Nothing is built. The equivalents are Block Store for the key pair and the group states, which is
made for small secrets that follow a person to a new phone through Google's restore, and Auto
Backup for files. The Android app, when written, keeps the same split: what restore needs in Block
Store, what can be made again in files, and the install ID device-only. Phones without Google
services have the coordinator route only.

## The MeshCore box after a restore

Bluetooth bonds do not move to a new phone, so the person pairs again. A box with a working screen
shows a fresh random code, as at the first pairing. A box whose screen has failed starts Bluetooth
with its label code (firmware/DESIGN.md, section 6), which the phone that provisioned it gets in
every info reply (0x70). Today the app keeps a box's code in the keychain by the phone's own
Bluetooth identifier for that box (`Store.boxPin`, `BoardLink` setting a random code on a box that
reported MeshCore's fixed one), which no other phone shares. The code and the label code are kept
by the box's own public key instead, in the restored keychain, so the Box tab can show "This box's
code" after a restore and the person pairs without finding the label. A stock box that reported
the fixed code and was given a random one is paired the same way; without the stored code it has
to be reset.

The box needs nothing from the phone: the group, the member list, the names it was given and the
label code are in its flash, and the restored phone is the same member it already lists. The phone
needs from the box its pairing, the info reply (which says whether the box is provisioned, its
unit, its next request number and its power), and the box's list of calls made while the phone was
away (0x73), which the phone carries on its other routes as it does after any reconnection. After
that the usual sync sends the box only what changed, and everything again if the box holds
nothing.

## Nine months away

A restored phone holds the group as it was when the keychain last synced, or when the backup was
made. What may have changed:

- **Members and settings.** The first coordinator repeats the signed member list daily and the
  settings travel with it, so the phone catches up on its first day back, over the relay or the
  radio, if it can open them.
- **Changeovers.** Every removal and takeover makes new group secrets; the old ones stop seven
  days later. A phone away through one holds dead keys: the relay still takes its signed requests
  and gives it messages it cannot open, and the radio gives it nothing. The app already shows the
  cross and "Your coordinator has a new code for you to scan, under Group" once it knows its keys
  are outdated; it must reach that state on coming back with nothing it can open, not only on
  hearing a changeover end. Any coordinator shows the update code, or sends it as a message
  (`KeyUpdatesSection`), sealed to the phone's public key, which the restore kept. The code
  carries the two takeovers before it, so a phone away through up to three takeovers catches up
  from one code. Away through more, it cannot open any code, and comes back by the coordinator
  route.
- **A takeover.** Under decision 20 as it stands, a takeover of a lost first coordinator removes
  their phone, and a restore of that phone months later finds it removed. Under Martin's redesign
  of 2026-11-02, a takeover is for an incapacitated coordinator and removes nobody, so the
  restored phone is a coordinator still, one step behind, and catches up from the update code;
  the person can take over again if they wish. A lost phone that is restored needs no takeover at
  all, which is the point of the decision.
- **The relay pass.** The pass is a group setting that reaches every member, so the restored phone
  gets the current one with the settings. A pass that lapsed has its own grace period, which is a
  payment matter and never a route for a phone change. If the group has no valid pass when the
  phone comes back, the internet route shows the cross, as for everyone.
- **Removed in its absence.** The relay refuses the phone (403: "The relay does not list this
  phone. Ask your coordinator to open Help&I.", `Relay.swift`), the radio gives it nothing it can
  open, and a box it pairs with no longer lists it. The app must say plainly: "You are no longer in
  this group. Ask your coordinator to invite you again." It must not show a cross alone, which
  would read as a route down rather than a membership gone.

## A phone lost, not replaced

A restore brings the person back; it does not shut the old phone out. A phone that was wiped before
it was sold holds nothing. A phone stolen or lost unwiped holds everything until the member is
removed, including a responder's copy of the responders' key. Removal is the only thing that
rotates it, and a removal removes the member, the restored phone with it, so the person then joins
again with new numbers. Whether that is acceptable, or a key change that keeps the member's numbers
is wanted for that case, is a question below.

## The fallback: no backup

Someone who declined the platform's backup, or whose backup was never made, comes back by what
exists today (app-spec.md, Removing a lost phone): the first coordinator removes the old member,
which makes new group secrets, sends every remaining member an update code and starts the seven
days on both channels; the relay refuses the old phone at once and every box forgets it when its
phone next connects. A coordinator then invites the person again, in person by QR code or at a
distance by link and safety number, as a new member with a new member number and unit number, and
sets their profile, their box's home, their check-in times and their name again. The old numbers
are never reused. The app tells someone who declines backup at setup that this is what a lost
phone means for them.

## Considered and not chosen

- A handover from the old phone to the new one by QR code or Bluetooth: a step the person has to
  remember, which is the risk Martin names.
- A passphrase-sealed file or printed recovery code the person keeps: a copy of a private key
  outside any phone, and a passphrase the people Help&I serves are the most likely to lose.
- "Replace this phone" on the coordinator's member page: a step no other app has; the fallback
  above is the same thing done by hand.
- A signed key change that keeps a member's numbers after a lost phone: kept as a question, not
  built.

## Decisions for Martin

- May one member's keys be active on two devices at once, an iPad and a phone on the same account,
  numbered apart as the watch is? Or one device at a time, the newest, with the other going quiet
  until it is taken back?
- When a phone is stolen or lost unwiped, the only way to shut it out today is to remove the
  member, which removes the restored phone too, and the person joins again with new numbers. Is
  that acceptable, or should the first coordinator be able to sign a key change that keeps the
  member's numbers?
- Should a box's pairing code and label code be kept in the person's synced keychain, so a
  restored phone pairs with a box whose screen has failed without reading the label? The label is
  a secret: a phone paired with it can set the box up for another group or wipe it.
- When someone declines the platform's backup at setup, should the app ask again later, and how
  often, or ask once and leave a line under Group?
