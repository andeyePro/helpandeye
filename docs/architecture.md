# How the prototype fits together

For contributors. What each part does and where its code is. The rules it follows are in
[design-decisions.md](design-decisions.md) and [app-spec.md](app-spec.md).

## Parts

| Part | Where | What it does |
|---|---|---|
| Core logic | `app/helpandeyeCore` | Swift package with no UI: message frames, request state, escalation, rota, check-ins, airtime, group keys, the MeshCore and relay protocols, and `HelpEngine`, which applies the rules. All tests are here (`swift test`), including end-to-end tests that run several engines over a fake radio and relay. |
| Phone app | `app/helpandeye` | SwiftUI screens, and the real box (`BoardLink`), relay (`Relay`), home Wi-Fi link (`HomeWiFi`), notifications and storage plugged into the engine. |
| Home Wi-Fi listener | `app/helpandeyeLocalPush` | A local push extension iOS runs on the named home Wi-Fi with the phone locked: it joins the first group's phones as the app does and alerts for a call (decision 19). It confirms only the calls it alerts for, so anything else sent to it goes on by the sender's other routes. Needs a signed build. |
| Watch app | `app/helpandeyeWatch` | Three buttons and a Help complication. In reach of its phone it sends through the phone. Out of reach it runs its own `HelpEngine` for each of the phone's groups, as the same member, and calls and responds over its own internet connection (`WatchHandover`). |
| Box | any Heltec LoRa board | MeshCore's standard companion firmware, unchanged. The app writes the group's private channel into it. |
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
(0x21 to 0x23). Integers are little-endian.

| Kind | Name | Fields after the first byte | Group channel |
|---|---|---|---|
| 0 | for responders | unit u32, request u16, part u8, then a 5-byte salt, the sealed inner frame and its 16-byte tag | yes |
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
| 0x22 | call state | unit u32, request u16, state u8, at u32, length u8, reason (up to 56) | inside 10; with a reason, the internet and home Wi-Fi only, and the radio gets it without |
| 0x23 | change request | member u16, setting u8, at u32, length u8, text (up to 60) | no; inside 10, from that member |

Every signature (kinds 3, 9, 10 and 0x21) also covers the group's ID, so one made in one group is
worthless in another.

Availability (4), notice acknowledgements (5), membership (11 to 15), call states (0x22) and
change requests (0x23) count only inside a signed frame (10) from someone allowed to send them: a
call state from the caller (I'm OK; a close only where their profile lets them close, or lets I'm
OK close) or from a coordinator (decision 6).

Personal content never goes on the shared group channel (decision 12). What a caller types,
chooses (a category such as Fallen) and where they are is signed by the caller and sealed once for
all responders (kind 0, `ForResponders`) with a key made from the caller's key and the responders'
public key. That one sealed frame goes on the group channel, the relay and home Wi-Fi alike; only
the group's responders can open it. Groups made before responders had their own key send these
plainly over the internet (sealed with the group key) and as MeshCore direct messages to each
responder's box instead. Member names, phone numbers, settings too big for the radio, reasons for
closing and change requests go over the internet and home Wi-Fi only. Check-ins go signed over
the internet and as direct messages (`HI1:` and the frame in base64), which MeshCore encrypts to
that box's own key. A direct message counts only if it came from the box of the member whose unit
it names; box keys are signed by their member.

## Home Wi-Fi (`LocalWire`)

The group's phones on one network find each other by Bonjour, under a name made from the group ID
that says nothing about the group, and keep a TCP connection open. Each end sends a random
challenge, then proves which member it is by signing the other's challenge, sealed with the group
key; a proof from this phone's own member or from anyone not in the group ends the connection.
Each end then derives two keys from the group key and both challenges, one for what it sends and
one for what it hears, new for each connection. Every frame is sealed with the sender's key and
numbered; a receipt returns that number with a digest of the sealed frame, sealed with the
receiver's key, once the receiver has taken it in. So a frame counts as sent only when another
member's Help&I has that frame, and nothing between the two phones can make up a receipt. A frame
for only some members (a change request, for the coordinators) counts only if one of theirs took
it in. A connection is dropped when who is in the group changes. A missing or late receipt does
not prove nobody heard, so the cross says "Not sent. Nobody may know you need help.", not that
nobody has been told.

## Keys

- Each phone has two key pairs, kept in its keychain and never sent: X25519 for receiving sealed
  group secrets, Ed25519 for signing acknowledgements and relay requests.
- Each group has a MeshCore channel secret (16 bytes) and a group key for the internet route (32
  bytes), made at random by the first coordinator's phone, and an ID made from that coordinator's
  signing key, which the relay checks.
- Joining is three QR codes, or the same codes sent as messages with a six-digit safety number read
  aloud. Removing a phone makes new group secrets, handed to every remaining member as an update
  code; the old channel stays readable for seven days while boards change over.
