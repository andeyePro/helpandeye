# App specification

Draft for the first Help&I phone and watch app. Decisions already taken are in
[design-decisions.md](design-decisions.md); this file says how the app carries them out, and
lists what is still open. Items marked **Proposed** are not yet agreed.

## Scope of the first release

- iOS phone app and watchOS app. Android follows.
- One app with two roles: a person can be a caller, a responder, or both.
- Routes: internet (mobile data or Wi-Fi), SMS, and the MeshCore mesh through a Heltec board on
  MeshCore's standard companion firmware, over Bluetooth.

## Groups and roles

- A **coordinator** sets up a group and invites its responders and callers. Joining is by
  invitation only, and each person accepts a consent screen saying what is sent and who sees it.
- **Responders** enter their availability. The coordinator is told when the rota has a gap.
- **Peer-to-peer groups** are allowed: every member is both caller and responder, as on a street
  or a works team.
- A group can have more than one coordinator, so that it does not depend on one person. Any
  coordinator can invite people and handles rota gaps and notices. Only the group's first
  coordinator removes people (which changes the keys) or makes new coordinators, so two
  coordinators out of touch can never split the group onto different keys. Each coordinator hands
  out member and unit numbers from their own block, so two adding people at once never clash. If
  the first coordinator's phone is lost, nobody can remove anyone; what should happen then is a
  decision for Martin (TODO.md).
- Someone invited by a coordinator other than the first is confirmed when their phone hears the
  first coordinator list them, which it does daily. If that has not happened within two days, or
  the coordinator who invited them is removed first, their phone says plainly that the others may
  not know they are in the group, and to ask another coordinator.
- If someone is removed after their acknowledgement reached a caller, the caller is told plainly
  that nobody has seen their call now, it goes out again, and responders are alerted again.

## Profiles

Agreed with Martin, 2026-10-28.

- A coordinator makes named sets of settings, called profiles, such as "Living alone" or "Lone
  worker", and gives one to each person who calls for help. Everyone starts on the group's
  standard profile.
- A profile covers what each button shows (words, an Apple symbol, or both; both by default:
  a raised hand, a helping hand and a tick), the sounds and spoken words, what I'm OK does after
  Help or Need a hand, sharing where they are, offering a text when nothing else got through,
  check-ins, and how often responders are alerted again. SOS is allowed as a button's words, with
  a warning to make doubly clear to the people on that profile that it does not replace 999.
- For each setting the coordinator chooses whether the person may change it. Settings they may
  not change are shown, but cannot be changed; beside them the person can ask the coordinator
  to change one. The request goes signed, over the internet only, and is shown under Group for
  coordinators. It is never on the call screen, so it cannot confuse anyone in an emergency.
- A profile can hide the settings page, so a caller sees only the three buttons. When a group
  with only one coordinator does that, the app suggests adding a second.
- Nobody can change the safety rules: nothing closes a call on its own, the cross shows when a
  call did not go, and the notice that Help&I does not replace 999 stays.

## Who is alerted

The app shares requests out fairly and prioritises the closest responder:

1. Only responders who are available now are considered.
2. If the group uses distance, the closest of them come first. Distance uses the caller's
   registered location, held on group members' phones and never sent on air.
3. Among responders at a similar distance, the one who has answered least recently comes first,
   so that the same person is not always called.
4. If nobody acknowledges within the group's escalation time, the next responder is added. The
   first ones are not dropped. Once the list runs out, the whole group and the coordinator are
   alerted. A request never closes or times out on its own.

Escalation comes after 2 minutes for red and 15 minutes for amber, adjustable per group.

## Messages

- Red or amber goes out the moment it is pressed, with nothing else in it but the unit number,
  the colour and a message number.
- Any follow-up (a category such as "fallen", or free text) goes as a separate message carrying
  the same request number. The responder app assembles them into one request.
- Over the internet route, follow-ups are end-to-end encrypted. Over the mesh, the call for help
  and the group channel carry only the unit number, colour, category code and request number.
  Short free text and the caller's position follow as encrypted direct messages to each
  responder, after the call for help, and only when there is airtime to spare
  ([decision 12](design-decisions.md#d12)).
- Red and amber are sent at once over every route that works without the caller's help, not
  just the first, and the responder app removes duplicates by request and message number. This
  replaces the "first route that works" order in [decision 8](design-decisions.md#d8). Mesh sends
  stay within the duty-cycle limit, so follow-ups go over the mesh only if no other route worked.
- A responder's acknowledgement goes back the same way. The caller sees "Seen by a responder"
  only after a human pressed acknowledge, and a cross if nothing could be sent at all.

## Closing a call, and I'm OK after a call

Agreed with Martin, 2026-10-28 ([decision 6](design-decisions.md#d6)).

- A call stays open until a person closes it: the caller, where their profile allows it, or a
  coordinator, who records either that the caller agreed or a reason, such as "spoke to them on
  the phone, all well". Nothing closes a call on its own. A close is signed by whoever made it.
- I'm OK pressed while Help or Need a hand is open does one of two things, set per profile:
  it closes the call (A), or it stops the urgent repeats while the call stays open until a
  responder has checked (B). New groups start on B. The words the caller hears are editable.
- A coordinator's reason is personal, so it goes over the internet only; the mesh carries the
  close without it.

## Routes

- **Internet:** see [How the internet route works](#how-the-internet-route-works).
- **SMS:** iOS does not let an app send an SMS on its own, so on iPhone SMS is not part of the
  first attempt. If every other route fails, the app offers a ready written text that the caller
  taps to send. Android sends automatically, as part of the first attempt.
- **Mesh:** the app sends through the paired Heltec board. A responder's phone paired with its
  own board receives the request over Bluetooth with no internet, and alerts them even when the
  app is in the background.

## How the home Wi-Fi route works

[Decision 19](design-decisions.md#d19).

- Each phone advertises itself on the Wi-Fi network with Bonjour, under a name made from the
  group's ID, so the group's phones find each other while the name tells no one else which group
  it is. Each pair keeps one direct connection open.
- Every message goes over it sealed with the group key, exactly as it would go to the relay, so a
  stranger's phone on the same network can neither read nor fake one. Calls, acknowledgements,
  notes, positions and settings all travel this way; what is too personal for the radio may go
  here, as it never leaves the house.
- It is the first route tried, and goes alongside every other route that works. A call that
  reached no other phone of the group shows the cross, as on every route.
- iOS stops an app listening in the background. To keep the route working with phones locked,
  the app uses Apple's local push connectivity on the home Wi-Fi network, which the coordinator
  names when setting the group up.

## How the internet route works

- Requests go end-to-end encrypted to a relay, which is a Cloudflare Worker. A group can also
  use a second, independent relay on a different provider, so that no single server or provider
  is needed.
- Each relay wakes responders' phones through Apple's and Google's push services, which is the
  only reliable way to wake an iPhone app. The push says only that a group has a call, because
  the relay cannot read who, and carries the message still sealed; the phone opens it to name the
  caller. It goes to every member at once, and each phone then alerts its own person in
  escalation order.
- Responders' apps poll the relays when opened, in case a push was lost.
- The relays see only encrypted messages and unit numbers.

## The relay's daily allowance

- The relay counts its use against its daily allowance. Before it runs out, the coordinator gets
  an alert they must acknowledge. If they do not, the group's responders are alerted too.
- If the allowance runs out, the app shows a cross for the internet route, never a silent
  failure.

## Alerts on the responder's phone

- Responder alerts need to sound through silent mode and Focus. On iPhone that needs Apple's
  Critical Alerts entitlement, granted on application. Apply for it with the fall-detection
  entitlement ([decision 18](design-decisions.md#d18)).
- Until it is granted, alerts are marked Time Sensitive, which gets through Focus but not silent
  mode, and the app tells responders so.

## Watch app

- Red, amber and green buttons, and the state of the last request.
- Sends through the phone, or directly over the watch's own mobile data if it has it.
- Does not replace the watch's own fall detection or emergency calling.
- A Help complication in every shape, and ready-made Apple faces (easy-read analogue and digital)
  with it large, added in one tap from the phone.
- Tapping the complication starts a 60-second countdown shown in the red button, vibrating every
  10 seconds. At 30 seconds with no touch it says "Calling for help in 30 seconds. Press I'm OK to
  stop, or Help to ask for help now." At 0 it sends Help.

## Keys and setting up a group

Decided for now, following common practice for end-to-end encrypted apps (Martin, 2026-10-27:
"use best practice, we can change later").

- Every phone makes its own identity key pair the first time the app opens. The private key stays
  in that phone's keychain, marked "this device only", and is never backed up or sent anywhere.
  Each Heltec board makes its own MeshCore identity in firmware.
- When a coordinator creates a group, their app makes three random secrets: a 16-byte MeshCore
  channel secret, a 32-byte group key for the internet route, and the group's ID. Nothing is
  built into the app or the firmware.
- Joining is by invitation. In person, the new member scans a QR code on the coordinator's phone.
  At a distance, the coordinator sends a one-time link and both phones show the same six-digit
  code, which they read to each other over the phone before the coordinator approves. The group
  secrets then go to the new member encrypted to their phone's public key.
- The app writes the channel secret into its paired board over Bluetooth, and sets a random
  six-digit Bluetooth PIN on the board, so that a stranger's phone cannot pair with it.
- Relays hold members' public keys only. Every request to a relay is signed with the phone's own
  key.

## Removing a lost phone

- The coordinator, or the member from a new phone, removes the lost phone. The relays refuse it at
  once.
- The coordinator's app then makes new group secrets and hands them to every remaining member as
  an update code, shown as a QR code or sent as a message, encrypted to that phone's key. Each app writes the new channel secret into its board the next
  time it connects. For seven days, phones listen and send on both the old and the new
  channel and keys, so members who have not scanned their update still hear calls and
  acknowledgements. The relay refuses the removed phone at once, so nothing personal reaches it.
- A removed phone's unit number is never reused.

## Who is in the group

- When a coordinator adds or removes someone, their phone tells every member at once, in a frame
  signed by the coordinator, over the internet and the mesh. So a new responder's acknowledgement
  counts on every phone straight away, and a removed one's stops counting. The new member's name
  follows over the internet only; with no internet they show as "Member" and their number.
- Member numbers are never reused, and a removed member can never be added back under the same
  number, so an old signed message replayed by a removed phone cannot let it back in.

## The log

Agreed with Martin, 2026-10-28.

- On by default; a coordinator can switch it off for the group. Each coordinator's phone keeps
  its own log of every press, delivery, acknowledgement, close and settings change it learns of,
  with who and when, encrypted on that phone. It is readable under Group and can be exported.
- Every settings change is logged and shown to the other coordinators.

## Rota gaps without internet

- Every member's app holds a copy of the rota and works out gaps for itself, so a coordinator
  learns of a gap from their own phone with no network at all, as long as their copy is current.
- When a responder changes their availability and there is no internet, the change goes over the
  mesh as a short group-channel message: their member number in the group and the times, with no
  name.
- A gap in the next 24 hours raises an alert that the coordinator must acknowledge. If they do not
  within an hour, the group's other coordinators are alerted, then its responders.

## Open questions

- How distance-based priority works for callers who move, such as walkers, using the position
  they send.
