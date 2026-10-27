# How the prototype fits together

For contributors. What each part does and where its code is. The rules it follows are in
[design-decisions.md](design-decisions.md) and [app-spec.md](app-spec.md).

## Parts

| Part | Where | What it does |
|---|---|---|
| Core logic | `app/helpandeyeCore` | Swift package with no UI: message frames, request state, escalation, rota, check-ins, airtime, group keys, the MeshCore and relay protocols, and `HelpEngine`, which applies the rules. All tests are here (`swift test`), including end-to-end tests that run several engines over a fake radio and relay. |
| Phone app | `app/HelpAndI` | SwiftUI screens, and the real box (`BoardLink`), relay (`Relay`), notifications and storage plugged into the engine. |
| Watch app | `app/helpandeyeWatch` | Three buttons. Sends through the paired phone. |
| Box | any Heltec LoRa board | MeshCore's standard companion firmware, unchanged. The app writes the group's private channel into it. |
| Relay | `relay/` | Cloudflare Worker. Stores and forwards sealed messages for the internet route. |

## A red press

1. The caller's app makes a request with the next request number and sends a 12-byte call frame at
   once on every route that works without the caller's help: the box (a MeshCore channel datagram,
   data type `0xFF48`, on the group's private channel) and the relay (sealed with the group key).
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

Every frame starts with one byte: format version 1 in the high nibble, kind in the low nibble.
Integers are little-endian.

| Kind | Name | Fields after the first byte | Group channel |
|---|---|---|---|
| 1 | call | unit u32, request u16, colour u8, pressed-at u32 | yes |
| 2 | follow-up | unit u32, request u16, part u8, category u8 | yes |
| 3 | acknowledgement | unit u32, request u16, responder u16, at u32, Ed25519 signature (64) | yes |
| 4 | availability | responder u16, from u32, until u32, available u8 | yes |
| 5 | notice acknowledged | notice u8, by u16, at u32 | yes |
| 6 | note | unit u32, request u16, part u8, length u8, UTF-8 text (up to 120) | no |
| 7 | position | unit u32, request u16, latitude i32 and longitude i32 (degrees × 10⁷), accuracy u16 | no |
| 8 | check-ins | unit u32, since u32, grace in minutes u16, count u8, minutes after midnight u16 each | no |
| 9 | box key | member u16, MeshCore public key (32), Ed25519 signature (64) | yes |
| 10 | signed | signer u16, length u8, inner frame, Ed25519 signature (64) | yes |
| 11 | member added | member u16, role u8, unit u32, signing key (32), sealing key (32), version u32 | inside 10, from a coordinator |
| 12 | member removed | member u16, version u32 | inside 10, from a coordinator |
| 13 | member name | member u16, length u8, UTF-8 name (up to 40) | no; inside 10, from a coordinator |
| 14 | role change | member u16, role u8, number block u16, version u32 | inside 10, from a coordinator |

Every signature (kinds 3, 9 and 10) also covers the group's ID, so one made in one group is
worthless in another.

Availability (4) and notice acknowledgements (5) count only inside a signed frame (10) from the
member they are about.

Frames marked "no" carry personal content and never go on the shared group channel (decision 12).
They travel over the internet route, sealed with the group key, and (notes, positions and
check-ins) as MeshCore direct messages to each responder's box (`HI1:` and the frame in base64), which
MeshCore encrypts to that box's own key. A direct message counts only if it came from the box of
the member whose unit it names; box keys are signed by their member.

## Keys

- Each phone has two key pairs, kept in its keychain and never sent: X25519 for receiving sealed
  group secrets, Ed25519 for signing acknowledgements and relay requests.
- Each group has a MeshCore channel secret (16 bytes) and a group key for the internet route (32
  bytes), made at random by the first coordinator's phone, and an ID made from that coordinator's
  signing key, which the relay checks.
- Joining is three QR codes, or the same codes sent as messages with a six-digit safety number read
  aloud. Removing a phone makes new group secrets, handed to every remaining member as an update
  code; the old channel stays readable for seven days while boards change over.
