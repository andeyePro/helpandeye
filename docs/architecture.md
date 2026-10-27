# How the prototype fits together

For contributors. What each part does and where its code is. The rules it follows are in
[design-decisions.md](design-decisions.md) and [app-spec.md](app-spec.md).

## Parts

| Part | Where | What it does |
|---|---|---|
| Core logic | `app/HelpAndICore` | Swift package with no UI: message frames, request state, escalation, rota, check-ins, airtime, group keys, the MeshCore protocol and the relay protocol. All tests are here (`swift test`). |
| Phone app | `app/HelpAndI` | SwiftUI. Caller and responder screens, the Bluetooth link to the box, alerts, the internet route. |
| Watch app | `app/HelpAndIWatch` | Three buttons. Sends through the paired phone. |
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

Frames marked "no" carry personal content and never go on the shared group channel (decision 12).
Today they travel only over the internet route, sealed with the group key.

## Keys

- Each phone has two key pairs, kept in its keychain and never sent: X25519 for receiving sealed
  group secrets, Ed25519 for signing acknowledgements and relay requests.
- Each group has a MeshCore channel secret (16 bytes), a group key for the internet route (32
  bytes) and an ID, made at random by the coordinator's phone.
- Joining is three QR codes, or the same codes sent as messages with a six-digit safety number read
  aloud. Removing a phone makes new group secrets, handed to every remaining member as an update
  code; the old channel stays readable for seven days while boards change over.
