# How the prototype fits together

For contributors. What each part does and where its code is. The rules it follows are in
[design-decisions.md](design-decisions.md) and [app-spec.md](app-spec.md).

## Parts

| Part | Where | What it does |
|---|---|---|
| Core logic | `app/helpandeyeCore` | Swift package with no UI: message frames, request state, escalation, rota, check-ins, airtime, group keys, the MeshCore and relay protocols, and `HelpEngine`, which applies the rules. All tests are here (`swift test`), including end-to-end tests that run several engines over a fake radio and relay. |
| Phone app | `app/helpandeye` | SwiftUI screens, and the real box (`BoardLink`), relay (`Relay`), home Wi-Fi link (`HomeWiFi`), notifications and storage plugged into the engine. |
| Home Wi-Fi listener | `app/helpandeyeLocalPush` | A local push extension iOS runs on the named home Wi-Fi with the phone locked: it joins the first group's phones as the app does and alerts for a call (decision 19). It confirms only the calls it alerts for, so anything else sent to it goes on by the sender's other routes. Needs a signed build. |
| Watch app | `app/helpandeyeWatch` | Three buttons and a Help complication. In reach of its phone it sends through the phone. Out of reach it runs its own `HelpEngine` for each of the phone's groups, as the same member, and calls and responds over its own internet connection (`WatchHandover`); its calls are numbered 32768 and up, apart from the phone's. Back in reach it gives the phone the calls it is still sending and the acknowledgements it made, and the phone's application context gives it the calls a person settled there, with their signed acknowledgements, so neither alerts for a call the other's owner has answered. |
| Box (prototype) | any Heltec LoRa board | MeshCore's standard companion firmware, unchanged. The app writes the group's private channel into it. |
| Box firmware | `firmware/` | Help&I's own build of MeshCore's companion firmware for the Heltec WiFi LoRa 32 V4 (option A, `firmware/DESIGN.md`): red, amber and green buttons, a buzzer, the screen, resends, acknowledgement checking, I'm OK, the duty-cycle budget and power cap, and a sealed power-cut and battery report, with the box as its own group member. The logic is a portable C++ core (`firmware/core`) with host tests (`make test`); `firmware/box` is the overlay on a pinned MeshCore commit and `firmware/build.sh` builds it. Compiles; not yet run on a board. The app recognises it and sets it up (below). |
| Relay | `relay/` | Cloudflare Worker. Stores and forwards sealed messages for the internet route. |

## A red press

1. The caller's app makes a request with the next request number and sends a 12-byte call frame at
   once on every route that works without the caller's help: the group's other phones on the same
   Wi-Fi (`LocalWire`, below), the box (a MeshCore channel datagram, data type `0xFF48`, on the
   group's private channel) and the relay (sealed with the group key).
   An unavailable route shows as "not sent" with its reason; if none was available, the cross shows
   at once.
2. The call goes out again after 30 seconds, 1, 2 and 4 minutes, then every 10 minutes, until a
   signed acknowledgement comes back. It never stops on a timer.
3. Each responder's phone hears the call, works out the same escalation order from the group, the
   rota and who answered last, and alerts its own person from their turn, counted from when the
   caller pressed, repeating until someone acknowledges.
4. A responder taps Acknowledge. Their phone signs an acknowledgement with its own key and sends it
   on every route, and again whenever it hears the call repeated.
5. The caller's phone accepts the acknowledgement only if it carries the signature of a current
   member who can respond, and only then shows "<name> has seen your call."

## Frames

`app/helpandeyeCore/Sources/helpandeyeCore/HelpFrame.swift` is the reference; this table follows
it. Every frame starts with one byte: format version 1 in the high nibble, kind in the low nibble.
The first 16 kinds used the low nibble up, so later kinds have whole header bytes of their own
(0x21 to 0x27). Integers are little-endian.

| Kind | Name | Fields after the first byte | Group channel |
|---|---|---|---|
| 0 | for responders | unit u32, request u16, part u8 (255 for a close with its reason), then a 5-byte salt, the sealed inner frame and its 16-byte tag | yes; a close with its reason, the internet and home Wi-Fi only |
| 1 | call | unit u32, request u16, colour u8, pressed-at u32 | yes |
| 2 | follow-up | unit u32, request u16, part u8, category u8 | only a missed check-in or a withdrawal of one; any other category goes inside 0 |
| 3 | acknowledgement | unit u32, request u16, responder u16, at u32, Ed25519 signature (64) | yes |
| 4 | availability | responder u16, from u32, until u32, available u8 | yes |
| 5 | notice acknowledged | notice u8, by u16, at u32 | yes |
| 6 | note | unit u32, request u16, part u8, length u8, UTF-8 text (up to 120) | no; inside 0 |
| 7 | position | unit u32, request u16, latitude i32 and longitude i32 (degrees × 10⁷), accuracy u16 | no; inside 0 |
| 8 | check-ins | unit u32, since u32, grace in minutes u16, count u8, minutes after midnight u16 each | no |
| 9 | box key | member u16, MeshCore public key (32), Ed25519 signature (64) | yes |
| 10 | signed | signer u16, length u8, inner frame (up to 80), Ed25519 signature (64) | as its inner frame |
| 11 | member added | member u16, role u8, unit u32, signing key (32), sealing key (32), version u32 | inside 10, from a coordinator |
| 12 | member removed | member u16, version u32 | inside 10, from a coordinator |
| 13 | member name | member u16, length u8, UTF-8 name (up to 40) | no; inside 10, from a coordinator |
| 14 | role change | member u16, role u8, number block u16, version u32 | inside 10, from a coordinator |
| 15 | member phone | member u16, at u32, length u8, number | no; inside 10, from that member or a coordinator |
| 0x21 | group settings | signer u16, version u32, length u16, compressed settings (up to 2,048), Ed25519 signature (64) | only when small enough; otherwise the internet and home Wi-Fi |
| 0x22 | call state | unit u32, request u16, state u8, at u32, length u8, reason (up to 56) | inside 10, without a reason; a coordinator's reason goes inside 0 (signed by the coordinator, sealed for responders) over the internet and home Wi-Fi only, and the radio gets the close without it |
| 0x23 | change request | member u16, setting u8, at u32, length u8, text (up to 60) | no; inside 10, from that member |
| 0x24 | changeover ends | generation u32, at u32: when the keys before that generation stop | inside 10, from the first coordinator |
| 0x25 | deputy | member u16 (0 for no one), the deputy's signing key (32), version u32, the first coordinator's Ed25519 signature (64) | yes |
| 0x26 | takeover | lost first coordinator u16, new first coordinator u16, membership version u32, deputy naming's version u32 (0 for none), count u8 (1 or 2), then signer u16 and Ed25519 signature (64) for each, then the deputy naming's signature (64) if its version is not 0 | yes |
| 0x27 | takeover agreed | lost first coordinator u16, the coordinator who may take over u16, signer u16, Ed25519 signature (64) | yes |

Every signature (kinds 3, 9, 10, 0x21 and 0x25 to 0x27) also covers the group's ID, so one made in one group is
worthless in another.

Availability (4), notice acknowledgements (5), membership (11 to 15), call states (0x22) and
change requests (0x23) count only inside a signed frame (10) from someone allowed to send them: a
call state from the caller (I'm OK; a close only where their profile lets them close, or lets I'm
OK close) or from a coordinator (decision 6).

Personal content never goes on the shared group channel (decision 12). What a caller types,
chooses (a category such as Fallen) and where they are is signed by the caller and sealed once for
all responders (kind 0, `ForResponders`) with a key made from the caller's key and the responders'
public key. That one sealed frame goes on the group channel, the relay and home Wi-Fi alike; only
the group's responders can open it. A coordinator's reason for closing a call is sealed the same
way, signed by the coordinator, so responders read it and other members, the caller included, do
not; it goes over the internet and home Wi-Fi only, and the radio carries the close without it.
Groups made before responders had their own key send these plainly over the internet (sealed with
the group key) and as MeshCore direct messages to each responder's box instead, and the reason
inside the signed close as before. Member names, phone numbers, settings too big for the radio and
change requests go over the internet and home Wi-Fi only. Check-ins go signed over
the internet and as direct messages (`HI1:` and the frame in base64), which MeshCore encrypts to
that box's own key. A direct message counts only if it came from the box of the member whose unit
it names; box keys are signed by their member.

## Home Wi-Fi (`LocalWire`)

The group's phones on one network find each other by Bonjour, under a name made from the group ID
that says nothing about the group, and keep a TCP connection open. Each end sends a random
challenge and a one-off X25519 key share, then proves which member it is by signing the other's
challenge and both shares, sealed with the group key; a proof from this phone's own member or from
anyone not in the group ends the connection. Each end then derives two keys from the group key, the
shares' secret and both challenges, one for what it sends and one for what it hears, new for each
connection; as the shares are signed, not even another member passing the messages along can learn
them. Every frame is sealed with the sender's key and
numbered; a receipt returns that number with a digest of the sealed frame, sealed with the
receiver's key, once the receiver has taken it in. So a frame counts as sent only when another
member's Help&I has that frame, and nothing between the two phones can make up a receipt. A frame
for only some members (a change request, for the coordinators) counts only if one of theirs took
it in. A connection is dropped when who is in the group changes. A missing or late receipt does
not prove nobody heard, so the cross says "Not sent. Nobody may know you need help.", not that
nobody has been told.

## A Help&I box and its phone

`BoardLink` asks every box for MeshCore's device info; a version ending `-hi1` (or any `-hiN`) is
a box on Help&I's firmware, and the Box tab says "Help&I box" against "MeshCore box". A stock box
gets none of what follows. The bytes are those of `firmware/DESIGN.md` section 6; `HelpBox.swift`
builds and reads them, and its tests pin them to DESIGN.md's tables and to bytes the firmware core
wrote.

- **The box as its own member.** It joins as a caller with its own unit. A coordinator pairs
  their phone with it once and taps Add this box: the phone takes the box's signing key (its
  MeshCore public key) and its sealing key (from the info reply, 0xA0), and adds it with the usual
  signed member add, so every phone knows it, choosing whose home it is in (the group setting
  `boxHome`, which the coordinator can change later). Anyone else's phone says to ask the
  coordinator. A box's calls count as a phone's own household's only while that phone is
  connected to it and it is in that member's home: it calls under their unit, or the coordinator
  chose them for it (`HelpEngine.householdBoxUnit`). That phone is never alerted for them, as for
  its own, and carries them. Any other phone connected to it, such as a coordinator's adding or
  setting it up, only hears what it pushes, as if on the radio, so a coordinator who responds is
  alerted from their turn like everyone else.
- **Setting it up.** The phone of the first group sends the group (0x71), the member list (0x72)
  and, if the group puts them on boxes, responders' first names (0x76): at pairing, at joining,
  and after any change of members or settings, sending only the parts that changed
  (`HelpBox.Sync`), and all of them again when the info reply says the box holds nothing. Names
  are off unless a coordinator turns them on (Advanced settings); with them off nothing is sent,
  except an empty list to a box that still holds some. The power-cut report is a coordinator's
  choice for each unit (its member page), and the antenna sets the box's power cap, both in 0x71.
- **The box's own frames.** The box sends its call on the radio itself, and pushes it (0xA3) to
  its phone, which keeps it as an `OutgoingRequest` marked `fromBox`, sends it on its other routes
  (internet, home Wi-Fi), resends it there like its own, and answers the box with 0x74: whether a
  route took it. Its signed I'm OK or close, and a sealed report, are taken in as if heard on the
  radio and carried the same way. The phone's own buttons, notes and I'm OK never touch the box's
  calls. An acknowledgement or a coordinator's close of the box's call that reached the phone
  another way goes on the radio, so the box, which hears only the radio, can show it.
- **Calls made while the phone was away.** On connecting again the phone reads the box's list of
  its calls (0x73, answered 0xA1 for each and then 0xA2) and carries any still waiting for a
  responder, or not sent, that it does not already have, on its routes as if pushed at the time,
  answering each with 0x74 (`HelpEngine.adoptBoxCalls`). Calls seen or closed are left.
- **A removed box.** When a box's member is removed, the phone connected to it tells it to forget
  the group (0x75), at the removal and again whenever it connects to it, so it stops calling as a
  member the others no longer accept. A box still in the phone's first group is never told to
  forget, whatever another group's list says.
- **A power cut.** The box's report is a request of its own with a Power cut follow-up and notes,
  sealed for responders. A responder's phone shows it calmly ("power cut at home", a calm
  notification, reminders every half hour and then every two hours) until a person acknowledges.
  A box without the mains wire adds the note "Power probably cut: the battery is falling.", and
  the phone then says "probably".
- **A stock box's battery.** A stock box tells the phone only its battery voltage. While the app
  runs, `BatteryWatch` reads it once a minute and decides on the mains exactly as the firmware's
  `MainsEstimate` does without the wire, so a full cell resting or a charger finishing never looks
  like a cut. If it judges the power gone, the caller is offered to tell responders: a Need a hand
  with the same "probably" note. The app is not running when iOS has suspended it, so this is a
  help, not a promise.

## Keys

- Each phone has two key pairs, kept in its keychain and never sent: X25519 for receiving sealed
  group secrets, Ed25519 for signing acknowledgements and relay requests.
- Each group has a MeshCore channel secret (16 bytes) and a group key for the internet route (32
  bytes), made at random by the first coordinator's phone, and an ID made from that coordinator's
  signing key, which the relay checks.
- Joining is three QR codes, or the same codes sent as messages with a six-digit safety number read
  aloud. Removing a phone makes new group secrets, handed to every remaining member as an update
  code; the old channel stays readable for seven days while boards change over. A phone that hears
  of a removal of someone who could respond before it has its update code sends nothing personal
  (choices, typed messages, position) until it is scanned, as the removed phone still holds the
  responders' key it would seal with; the call itself still goes.
- If the first coordinator's phone is lost, another coordinator takes over (decision 20). The
  first coordinator may name a deputy (0x25): signed over the group ID, the deputy's signing key
  and a version, so a later naming, of someone else or no one, replaces it. A takeover (0x26) is
  signed by the coordinator taking over, over the group ID, the lost phone's signing key and their
  own, and carries its proof: the deputy naming, a second coordinator's signature over the same
  bytes (sent to them as 0x27), or nothing more, which each phone accepts only once it has itself
  heard nothing signed by the first coordinator for seven days. Every phone checks it against its
  own member list, removes the lost phone and follows the new first coordinator; the new first
  coordinator's phone makes new keys as after any removal. The takeover is repeated with the
  member list during the changeover and travels inside each update code, so a phone that missed it
  catches up from either. Signing over keys rather than member numbers lets the relay check the
  same bytes.
- The group keeps its ID through a takeover. The relay, which made the group's owner the key the
  ID was made from, takes a new owner only from a member list sent by that new owner with the
  takeover in keys (`takeover` in `PUT /members`): every signature a current coordinator's, the
  lost owner among the removed, and proof as above, where the seven days are the relay's own: no
  request from the owner in that time. A list sent by anyone else carrying a takeover the relay has
  not taken waits (425).
- A new group uses Help&I's relay unless its coordinator sets their own or none (Group, Internet
  route). Help&I's relay is free to groups only while it costs Help&I nothing; once Help&I pays
  for it, it requires a relay pass for each group: a compact token naming the group and an
  expiry, signed by Help&I's issuer key, which the relay checks before anything else (with the
  signature, before its storage is touched) and which carries nothing personal. A coordinator
  pastes the pass in under Group, Internet route; it is a group setting, so it reaches every
  member like the relay address, and every member's phone sends it with each request. How a pass
  is bought is not decided (TODO.md); the relay does not care.
