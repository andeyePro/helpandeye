# Moving to a new phone

A design proposal, not yet agreed and not built. It answers the TODO item "Moving to a new phone
without iCloud Keychain or Google backup" (Martin, 2026-11-02). Decisions already taken are in
[design-decisions.md](design-decisions.md); how the app keeps its keys today is in
[app-spec.md](app-spec.md) (Keys and setting up a group) and [architecture.md](architecture.md)
(Keys).

## Where this starts from

Martin, 2026-11-02: keys follow a person to a new phone through iCloud Keychain or Google Block
Store, and the app asks them to turn that on at setup. Someone who declines still needs a way to
hand over. Until that is designed, nothing built may tie the apps to Apple's or Google's services,
so they stay fully usable outside both. That rule holds for every option below: each one works
with Help&I's own codes, links and files, and iCloud Keychain or Block Store is only a convenience
on top.

Today a phone's keys are marked "this device only" (`app/helpandeye/Store.swift`), so they never
leave the phone, in a backup or otherwise. The same keychain holds the group: its secrets, member
list and settings, and this phone's request counter. Open calls are in a protected file. The watch
holds a copy of its owner's keys and group, handed over by the phone; it is not a way back, as a
watch moved to a new phone is erased unless the phone's backup brings it back.

Whether Apple's own phone-to-phone transfer moves "this device only" items has not been checked
on a device. Nothing here depends on it.

## What is lost when the keys do not move

A member is their phone's key pair. The group's member list, the relay and every box hold the
public halves; nothing else names the person. So a phone whose keys are gone loses, for each of
its groups:

- its place in the group: its member number, and its unit number if it could call;
- its copy of the group's secrets: the channel secret, the group key for the internet route and,
  for a responder or coordinator, the responders' key (decision 12);
- its role, its profile and its own settings, its check-in times and its availability;
- its open calls and the acknowledgements it holds, and on a coordinator's phone the group's log,
  which lives only there (exportable, but only while the phone works);
- for a first coordinator, the group's authority: only that phone removes people, changes keys,
  names a deputy and makes coordinators;
- the Bluetooth code it set on its box, and its place as the phone a Help&I box in that home sends
  through on the internet and home Wi-Fi.

What the group sees, with nothing done, is nothing at first. The member stays in the list. A
caller's calls stop, but their Help&I box, which is a member in its own right (decision 8), still
calls on the radio; only its internet route through the phone stops. A responder's turn in the
escalation order passes in silence until the next responder is added, so each call takes a turn
longer to reach someone. A first coordinator's daily member list stops, which starts the seven-day
clock in decision 20 and, two days on, leaves anyone invited by another coordinator unconfirmed.

The old phone, if it still exists, is as much a member as it ever was. A phone handed on to a
grandchild without being wiped, or stolen, can acknowledge calls as that person and, if they were
a responder, read what callers seal for responders. Removing the member is the only thing that
shuts it out, because the responders' key is rotated only by a removal or a takeover.

So there are two cases, and they need different answers: a phone that is replaced, with the old
one in the person's hand; and a phone that is lost or broken.

## Options

Each option is described the same way: how it works, what the person does, what can go wrong, and
what it costs the group and the coordinator.

### A. Handover from the old phone to the new one

How it works: the old phone shows its keys and every group it is in as a code, sealed to the new
phone (the new phone shows its fresh public key first, the old phone seals to it, as an invitation
does today). The transfer can be the two QR codes, or over Bluetooth or the same Wi-Fi with the
six-digit safety number read off both screens, as joining at a distance does. The new phone takes
the request counter too, so no call number is ever used twice under the one unit. The old phone
then forgets everything, so there is one holder of the keys, as there was before.

What the person does: on the new phone, "I am moving from another phone"; on the old one, under
Group, "Move to a new phone"; hold them together. Nobody else is involved.

What can go wrong: the old phone is already lost or broken, and this option does nothing. The
transfer is interrupted after the new phone has the keys but before the old one forgot them, so
two phones hold one member; the new phone must say so until the old one is confirmed wiped, or the
person removes it by the coordinator route. The old phone cannot read its keychain before its first
unlock after a restart; the app already says so.

What it costs the group: nothing. The member, unit, keys, role and settings are unchanged. Nothing
goes on air. The coordinator does nothing and is not told.

Needs both phones working. Does not survive a lost or broken phone. Needs no coordinator.

### B. An export the person keeps

How it works: the app writes the person's key pair, and the groups as they stand, into a file
sealed with a passphrase the person chooses, or shows a recovery code to print and put in a drawer.
On a new phone the person opens the file or scans the code. The key pair never changes, so a code
made at setup is good for the life of the membership. The group's secrets change at every removal
and takeover, so a snapshot of them is good only until the next one, and dead seven days after it.
The new phone can tell: it hears nothing, or hears a changeover it cannot open. It then needs a
coordinator to send the group's current secrets again, sealed to the same public key, which any
coordinator's phone can do today as it does an update code.

What the person does: at setup, or later under Group, "Keep a copy of my keys", choose a
passphrase or print the code, and keep it safe. On a new phone, "I have a copy of my keys". If the
groups have changed since, ask any coordinator to "send my code again".

What can go wrong: the passphrase is forgotten, which for the people Help&I is for is the common
case, and the file is then worthless. The printed code is found by someone else, who is then that
member on any phone, for as long as the member exists; the person may never know. The copy was
made before the last removal and the person does not realise the group has moved on. The old
phone, if lost rather than replaced, still holds everything: this option restores the person but
does not shut the old phone out, and nothing can, short of removing the member (C). Someone who
declined iCloud Keychain to keep their keys on one phone is being asked to put them on paper.

What it costs the group: nothing on air. The coordinator does nothing in the simple case; where the
group has changed since the copy was made, they send one code to one person.

Survives a lost or broken phone. Needs no second phone. Needs the coordinator only when the group's
keys have changed since the copy. Does not shut out a lost phone.

### C. Rejoin as a new member, with the old one removed

How it works: the rules that exist today. The first coordinator removes the old member, which
makes new group secrets, sends every remaining member an update code (sealed to their phone over
the internet, or shown as a QR code), and starts the seven days on both channels. The removed
unit and member numbers are never reused. A coordinator then invites the person again, in person
by QR code or at a distance by link and safety number, as a new member with a new number and a new
unit number. The relay refuses the old phone at once; every box forgets it when its phone next
connects.

What the person does: tell a coordinator; scan the invitation on the new phone; set their own
settings again.

What can go wrong: the person is a caller whose coordinator is away for a week, and has no way to
call in the meantime except their box. A mesh-only group, with no internet, needs every member to
scan their update code in person within seven days, or they stop hearing calls. The coordinator
forgets to move the profile, the box's home, the check-in times, the rota, the deputy naming and
the name and phone number across, as each is keyed by member number; the app should offer to
carry them over in one step. The log and the person's old open calls are gone. If it was the first
coordinator's phone, there is no first coordinator to remove it: that is decision 20, below.

What it costs the group: a key change for everyone, with a code to scan where there is no
internet. The coordinator does the removal and the invitation, and sets the member up again.

Survives a lost or broken phone. Needs the first coordinator for the removal and any coordinator
for the invitation. The only option that shuts out a lost phone.

### D. Same member, new keys

Not built today. A member's phone gets a new key pair, and the first coordinator signs a change
of that member's public keys, as a role change is signed now, with the usual key rotation. The
member number and unit stay, and everything keyed by them stays with the person. It costs the
same key change as C, and new work: a frame kind, the relay's and the box's member lists, and a
rule that a message signed by the old key counts for nothing after the change. It is C with a
smaller mess for the coordinator, and it needs the coordinator exactly as C does. It is listed so
the question "keep the number, or give a new one" can be asked plainly.

### E. A combination

A for the replaced phone, C (or D) for the lost one, and the app telling the person which applies.
B as an extra for whoever wants it, or not at all.

## How each option meets the rules

- **Takeover (decision 20).** As it stands, a takeover removes the lost first coordinator's phone
  and rotates keys, so the lost first coordinator comes back by C, as an ordinary member. Under
  Martin's redesign of 2026-11-02 (not yet in the decisions table) takeover is for an incapacitated
  coordinator and removes nobody's phone, so a lost first coordinator's phone would stay in the
  group until the new first coordinator removes it. The redesign has to say that this happens, or
  the responders' key stays with a phone nobody holds. A, B and D are the same whoever the member
  is; nothing in them changes who is first coordinator.
- **The responders' key (decision 12).** Only C and D rotate it. A keeps one holder, which is as
  safe as today, provided the old phone wipes itself. B puts a copy outside any phone, which is
  new: a caller's copy has no responders' key, but a responder's or coordinator's does.
- **Seven days after a removal.** C and D cost the group that changeover. A costs nothing. A copy
  made under B is dead seven days after any removal it predates, and the app must say so rather
  than show a cross.
- **The 30-day grace.** The grace after a relay pass lapses (Martin, 2026-11-02, T18) is a payment
  grace, once in twelve months. The pass is a group setting that reaches every member, so a lost
  phone does not lapse it; a paying coordinator who comes back by C needs to be made a
  coordinator again before they can put the renewed pass in. The grace must never be spent on a
  phone change, and no option here touches it.
- **Nothing depends on Apple or Google.** All of A to D use Help&I's own codes, links and files.
  iCloud Keychain and Block Store, when on, make A unnecessary and B redundant for the people who
  have them, and change nothing else. Turning them on means marking the keychain items
  synchronisable rather than "this device only", which also puts the same member on every device
  signed in to that account, an iPad included; see the questions.

## Recommendation

Build A, and give C a "Replace <name>'s phone" step on the coordinator's member page that does
the removal and the new invitation together and carries the profile, the box's home, the check-in
times, the name and the phone number to the new number. The setup screen that asks for iCloud
Keychain or Block Store says, to someone who declines, that moving to a new phone later is done
from the old phone, and that a lost phone means asking their coordinator. Do not build B, and
leave D until a group asks to keep its numbers.

The reason: A covers the ordinary case, a planned upgrade, with no one else involved and no key
change, which is what a person who declined the platform's sync most plausibly wants. C already
exists, is the only route that shuts out a lost phone, and is what Martin's "no back door" answer
of 2026-11-02 points to: a group is a set of phones its coordinator vouches for, and a phone
nobody can vouch for is removed, not restored. B is the one option that creates a copy of a
private key outside any phone, with a passphrase the people Help&I serves are the most likely to
lose, and it still cannot shut out a lost phone.

The strongest argument against: the person who declined iCloud Keychain is exactly the person who
most wants not to depend on anyone, and with A and C alone a broken phone leaves them dependent on
a coordinator, who may be themselves. A couple, or a works team of three, who lose the first
coordinator's phone with nobody named, set the group up again from nothing. B is the only option
that gets such a person back without a coordinator and without a working old phone, and a printed
code in a drawer, which Help&I's unit label already is, may be a smaller risk than a group that
cannot be rebuilt. If that argument wins, B should be a choice under Group, never pressed on
anyone at setup, and the code should restore the key pair only, never a copy of the responders'
key.

## Decisions for Martin

- When both phones work, should the app move a person's keys from the old phone to the new one
  itself, and wipe the old phone afterwards? The alternative is the coordinator route for every
  change of phone.
- May one member's keys be on two devices at once? iCloud Keychain, once on, puts them on every
  device signed in to that account, an iPad included; the watch already acts as the same member
  with its calls numbered apart. If not, the app must refuse to run as a member already active on
  another device.
- Should the app offer a copy of the keys that the person keeps outside the phone, as a
  passphrase-sealed file or a printed code? If so, at setup, or only on request under Group? And
  should it ever include a responder's copy of the responders' key?
- When a phone is lost, should the person come back with their old member and unit numbers (a
  key change signed by the first coordinator, new work) or with new ones (remove and invite again,
  which exists)? Unit numbers appear in the log and on anything printed for the unit.
- Under the takeover redesign of 2026-11-02, which removes nobody's phone, who removes a lost first
  coordinator's phone, and when? Until it is removed it holds the responders' key.
- Which coordinators may replace a member's phone? Removal is the first coordinator's alone, so
  that two coordinators out of touch never split the keys; invitation is any coordinator's.
- When someone declines iCloud Keychain or Block Store at setup, should the app say then what to
  do instead, or leave it to a line under Group?
- Should a handover between phones carry the person's open calls, their acknowledgements and a
  coordinator's log, or only the keys and the groups?
