# Help&I box firmware: design

**Status: a proposal, untested on hardware.** Nothing in `firmware/` has run on a board. The
portable core (`firmware/core`) compiles and passes host tests on a Linux PC; that is all. The
choice between the options below is Martin's (TODO.md, "Buttons on a plain Heltec"). Until he
makes it, decision 8 stands and the prototype keeps MeshCore's stock companion firmware.

MeshCore references are to `meshcore-dev/MeshCore` at commit `81dbae5` (15 October 2026).

## 1. The question

The box today is a Heltec WiFi LoRa 32 V4 running MeshCore's standard companion firmware. It
has one user button (PRG, GPIO 0) and no buzzer, and it only relays what the phone app tells it
to send. Every Help&I rule runs in the phone app (`app/helpandeyeCore`). So with the phone flat,
out of Bluetooth range or switched off, the box does nothing for the person at home.

AGENTS.md says the buttons work alone: no core function may depend on the phone, Bluetooth,
Wi-Fi or the internet. Decision 1 puts three physical buttons on the unit. Decision 8 says the
box is a standard Heltec board with nothing added. These cannot all hold. The firmware decision
is which to give up.

## 2. The options

**A. Help&I firmware built on MeshCore.** MeshCore's companion firmware, unchanged as a radio
and as a Bluetooth companion for the phone, plus a Help&I layer on the board: three wired
buttons, a buzzer, the screen, call frames, resends, acknowledgement checking, I'm OK and the
duty-cycle budget. Red, amber and green work with no phone at all. The phone still adds the
internet, home Wi-Fi, typed messages, position and everything a responder or coordinator does.

**B. Stock firmware, with buttons that reach the box through a phone.** A Bluetooth button, the
phone or the watch starts a call; the phone sends it through the stock box. No firmware to
maintain. But every call depends on a phone and Bluetooth, which AGENTS.md rules out for a core
function. It is today's prototype with a remote control added.

**C. A separate hub.** A second small board (another ESP32, say) with the buttons, buzzer and
screen, running the same Help&I logic and driving a stock MeshCore companion board over a
serial cable using the companion protocol the app already speaks (`MeshCore.swift`). MeshCore
stays stock. The hub could also take several phones at once over Wi-Fi, which a stock board
cannot (TODO.md, "One box for a household").

| | A | B | C |
|---|---|---|---|
| Buttons work with no phone | yes | **no** | yes |
| MeshCore stays stock | no (a Help&I build of it) | yes | yes |
| Boards per home | 1 | 1 | 2 |
| Power drawn in a power cut | one board | one board | two boards |
| Help&I code on the board | yes | no | yes, on the hub |
| Updating the radio firmware | Help&I's release | MeshCore's | MeshCore's |
| One box for a household | possible later (section 4) | no | easiest |
| Fits decision 8 as written | no | yes | no |

B fails the first row, so it is not a way to meet AGENTS.md; it is listed because it is the only
option that keeps decision 8 unchanged.

## 3. Recommendation: A

Build A. One board, one battery, one thing to set up, and the buttons, buzzer and cross work in a
power cut with the phone dead. Keep the Help&I logic in a portable core with no Arduino or
MeshCore dependency (this folder), so it can move to a hub (C) later without being rewritten.

Build it as a Help&I user interface for MeshCore's companion firmware, not as a fork of its
internals. MeshCore's companion build already has a pluggable UI task (`AbstractUITask`, which
is a `MyMesh::Listener` and is told about every group datagram in `onChannelDataRecv`), drives a
buzzer when a board defines `PIN_BUZZER`, and has a public `sendGroupData`. A Help&I UI task in
place of `ui-new` touches MeshCore in a few hooks, and the Bluetooth companion protocol stays as
it is, so today's app keeps working with the new box.

**The strongest argument against A.** Help&I would then own safety-critical radio firmware for
good: every MeshCore release must be merged, built, tested on real boards and put on boxes in
the homes of people who cannot plug in a USB cable. A has the same Help&I logic as C, so its only
real gain over C is one board fewer; C buys stock, independently updated radio firmware with
that second board. If Help&I cannot commit to tested firmware releases and a way to update boxes
in the field, C is the safer choice, and the core here moves to it unchanged.

Either A or C means revising decision 8 ("with nothing added"): both add buttons, a buzzer and a
mains sensor to the board.

## 4. What the box does, and what stays in the app

On the box (A):

- Red, amber and green: a call frame on the group channel at once, then resent until a person
  settles it (section 7).
- Checking acknowledgements: only a current responder's signed one counts, and only then does
  the box say someone has seen the call.
- I'm OK: settles open calls as the caller's profile says (A closes, B stops the urgent
  repeats), signed by the box.
- What the person sees and hears: the state of the last call on the screen, the cross when
  nothing could be sent, sounds for a press, the countdown, "seen" and the cross.
- Keeping inside IR 2030: the duty-cycle budget and the transmit power cap (section 8).
- Mains and battery: detecting a power cut and the battery's hours left (section 10).
- Telling the paired phone, when there is one, about its calls, so the phone carries them on its
  own routes too (internet, home Wi-Fi).

In the app, unchanged:

- Joining, keys, key updates, removing people and group settings (the QR codes and safety
  number). The phone provisions the box over Bluetooth (section 6).
- The internet, home Wi-Fi and SMS routes, and the relay.
- Typed messages, choices such as Fallen, and position, sealed for responders (decision 12).
- Everything a responder does: alerts, escalation, rota, acknowledging. A box does not
  acknowledge, so it needs no responder's key.
- Everything a coordinator does: closing with a reason, the log, profiles, change requests.
- Watching for missed check-ins (the box's green presses are heard on the mesh like the app's).

**One box for a household.** With the box as its own member (section 6), its buttons call for
the household and need no phone. Sharing it as the radio for several phones needs the board to
accept more than one Bluetooth connection, which MeshCore's companion does not; that is later
work and not needed for the buttons.

## 5. Hardware

Per unit, on top of the Heltec V4 (OLED version):

- **Three buttons**: a large red (help), small amber and green (decision 1). Momentary, normally
  open, to ground, with the ESP32's internal pull-up and a 100 nF capacitor across each against
  contact bounce and interference. Illuminated buttons help people with poor sight find them.
- **A buzzer**: a passive piezo driven by PWM through a small NPN transistor, loud enough for
  someone hard of hearing. MeshCore's generic buzzer support already uses `PIN_BUZZER`.
- **An LED** for the box's state where the screen cannot be seen (dark room, poor sight).
- **Battery sensing**: already on the board. `PIN_VBAT_READ` is GPIO 1, switched by
  `PIN_ADC_CTRL` (GPIO 37); `HeltecV4Board::getBattMilliVolts` reads it.
- **Mains sensing**: a divider (say 100 kΩ over 100 kΩ) from the board's 5 V pin, which carries
  USB power, to a GPIO. With the box on a mains USB adapter, 5 V present means mains is on. A
  power bank or UPS between the adapter and the box would hide a power cut, so the setup
  instructions must say to plug the adapter straight into the wall.
- **A LiPo cell** on the board's battery connector, sized for decision 4's 24 hours and more.
- **A label** saying Help&I does not replace 999 or telecare (decision 13).

### Pins on the Heltec V4

Taken by the V4 in MeshCore's `variants/heltec_v4/platformio.ini`: 0 (PRG), 1 (battery), 2 and 5
(power amplifier enables), 7 (amplifier power), 8 to 14 (LoRa), 17, 18 and 21 (OLED), 35 (white
LED, lit while sending), 36 (Vext), 37 (battery read enable), 34, 38, 39 and 42 (GPS header),
46 (amplifier mode), 43 and 44 (serial). Avoid ESP32-S3 strapping pins 0, 3, 45 and 46, and the
USB pins 19 and 20.

Proposed, **all to check against Heltec's V4 schematic and on a board**:

| Use | GPIO | Why this one |
|---|---|---|
| Red button | 6 | RTC pin, so it can wake the board from deep sleep on battery |
| Amber button | 15 | RTC pin |
| Green button | 16 | RTC pin |
| Mains sense | 4 | RTC pin, so a power cut or its end wakes the board. Free only if no I2C sensor uses 3 and 4 (the Arduino default `SDA`/`SCL` in `pins_arduino.h`) |
| Buzzer | 47 | PWM capable, unused |
| State LED | 48 | unused |

GPIO 15 and 16 are the ESP32-S3's 32 kHz crystal pins; if the V4 fits that crystal they are
taken and the buttons move to free header pins. The TFT version of the V4 uses 3, 4, 15, 16, 17,
18, 21 and 33, so it needs its own pin list.

**Transmit power.** On the V4, MeshCore's setting is the SX1262's own output, before the power
amplifier: its build comment says a setting of 10 gives 22 dBm, about 12 dB of gain. The
licence-exempt limit is ERP at the antenna, so the cap has to allow for that gain and for the
antenna (section 8). The gain must be measured, on both the GC1109 (V4.2) and KCT8103L (V4.3)
amplifiers, before any box goes out.

## 6. Keys, identity and provisioning

No secret is built into the firmware (AGENTS.md). Everything the box holds is made on the box or
handed to it by the phone at join, over Bluetooth pairing confirmed with the random code
MeshCore shows on the box's screen.

**The box as its own member (recommended).** The box joins the group as a caller in its own
right, with its own unit number, like a person who only calls. Its keys are made on the board
and never leave it: an Ed25519 key for signing and an X25519 key for receiving sealed key
updates (MeshCore's own identity is an Ed25519 key made on the board; whether to reuse it or make
a second, Help&I-only key is an open question below). A coordinator adds it with the usual
signed `memberAdded`, carrying the box's public keys. Then every rule the phones apply today
already works for it, with no change to the app's frame rules: its calls carry its unit, its
I'm OK is a `callState` signed by a member whose unit it is (Engine.swift, `sender.unit ==
unit`), and its own close is allowed where its profile lets the caller close. Responders see
"Unit n" until their member list has its name, such as "Kitchen box at no. 4".

The alternative, the box acting for a person's own unit, would need either that person's signing
key copied onto the box (a private key on a device anyone can unplug and read) or a new rule in
the app accepting signatures from a member's box key. Both are worse for a first build.

What the phone gives the box, kept in its flash:

- The group ID, and the MeshCore channel secret: the current one and, during a changeover, the
  old one for its seven days (the box sends on both, as `MeshHub` does, and counts airtime for
  both).
- Its member number and unit number.
- The member list: number, role and Ed25519 public key for each member, and which member is the
  first coordinator. Needed to check acknowledgements (only a member who can respond) and
  removals. No names, phone numbers or anything else personal.
- Its profile's I'm OK setting (close the call, or stop the urgent repeats) and whether the
  caller may close a call.
- The time.

What the box never gets: the internet group key (it has no internet route), any responder's or
the responders' private key, and anything personal.

**Keeping the member list current without a phone.** The phones already repeat signed membership
frames on the channel. The box applies a `memberRemoved` it hears on air when it is signed by the
first coordinator (the same rule the app uses), and takes back acknowledgements from that member
at once (`OutgoingCall::revoke`). New key secrets after a removal arrive only through the phone,
as today.

**Signing and checking.** Ed25519 over exactly the bytes HelpFrame.swift signs:
`ackSignatureInput` and `signedSignatureInput` in `core/frame.hpp` build them, and the tests pin
them to the Swift layout. MeshCore already links an Ed25519 library (`lib/ed25519`, used by
`mesh::Identity`). CryptoKit's `Curve25519.Signing` is Ed25519, reportedly with randomised
signatures, which any RFC 8032 verifier should still accept; that needs one signed acknowledgement
from a real phone, checked on the board, before it is relied on.

**Protecting the keys.** ESP32-S3 flash encryption and secure boot would stop someone who takes
the box from reading its keys, but make reflashing harder for contributors. Open question.

## 7. Calls, resends and acknowledgements on the board

Matching `Resend.swift`, `OutgoingRequest` (Requests.swift) and `checkResends` (Engine.swift),
in `core/call.hpp`:

- A press makes a call with the box's next request number, written to flash before it is sent,
  so a restart never reuses a number. With the box as its own unit, it numbers 1 to 32767 like a
  phone.
- The 12-byte call frame goes on the group channel at once, as urgent airtime.
- It goes again 30 s, 1, 2 and 4 minutes after the press, then every 10 minutes, until a person
  settles it: a valid acknowledgement, or a close. Nothing stops it on a timer. After a long
  sleep, missed slots are skipped, not sent back to back. Resends use the optional share of the
  airtime (section 8), so they never use up what a new press needs. A call the radio could not
  send is retried on the same times.
- An I'm OK call is repeated on the first four resend times, then left.
- While a call stands at I'm OK (profile B), the signed I'm OK goes with each resend, so a
  responder who missed both still comes to check.
- A close the box made is repeated on the call's resend times four times.
- An acknowledgement counts only if it names this unit and request, was made no more than five
  minutes before the press by the sender's clock, and carries the valid signature of a current
  member who can respond. The box checks the signature and membership before
  `OutgoingCall::receive`, which checks the rest.
- What the box shows follows `CallerStatus`: sending, sent and waiting for a responder, seen,
  the cross (nothing could be sent by the box or by its phone), or closed. There is no
  "delivered": the radio sending is not a person reading it (decision 7). The words follow the
  app's ("Not sent. Nobody may know you need help. If you need help now, call 999.").

The core uses the board's monotonic clock for the schedule and the wall clock only for what goes
in frames, so the phone setting the time mid-call never moves a resend.

**Pressing again.** In the app, each press of Help is a new call. On a box someone may press red
over and over while waiting. Whether a repeat press while a call is open makes a new call, or
sends the open one again at once, is an open question below.

## 8. Airtime and transmit power

`core/airtime.hpp` follows `Airtime.swift`:

- Time on air per packet by Semtech's formula, explicit header and CRC on, low data rate
  optimisation when a symbol is over 16 ms.
- The two IR 2030 sub-bands MeshCore uses in the UK: 868.0 to 868.6 MHz (1%, 25 mW ERP) and
  869.4 to 869.65 MHz (10%, 500 mW ERP). Outside them the box sends nothing of its own.
- A one-hour sliding budget: calls up to 90% of the legal allowance, everything else, resends
  included, up to 50%. Airtime is reserved before sending and given back only if the radio
  refused the packet. The log has a fixed size; when it fills, the oldest entry is folded into the
  next one, which keeps it counted for longer, never shorter.

Two differences from the Swift code, both towards counting more airtime, never less:

- **Packet size.** MeshCore's `sendGroupData` puts the data type and a length byte before the
  payload, so the encrypted part is 3 + payload bytes. `meshPacketBytes` in Airtime.swift uses
  2 + payload, which comes out a whole 16-byte block short whenever the payload is 14, 30, 46...
  bytes. The core uses 3. On the board the firmware should use the real packet length
  (`Packet::getRawLength`) rather than any estimate.
- **Preamble.** MeshCore uses a 32-symbol preamble at spreading factor 8 and below, and 16 above
  (`RadioLibWrapper::preambleLengthForSF`). The Swift `RadioSettings` defaults to 16 and the
  companion protocol does not report it, so at the UK narrow preset (SF8, 62.5 kHz) the app
  counts a 21-byte packet as 312 ms when it is 378 ms. The core takes the preamble as a field,
  and the board knows its own.

**After a restart.** The Swift budget is saved so a relaunch does not get a fresh hour. A board
that lost power has no record of the hour before. Proposed: keep the log in RTC memory, which
survives a reset but not a power cut, and after a cold start count the optional half as used for
the first hour, so only calls go until the hour has passed. Open question below, because it also
trims the room left for calls in that hour.

**Transmit power.** `maxRadioPowerSetting` turns the band's ERP limit into the highest SX1262
setting, given the antenna's gain and the amplifier's gain, and refuses to send at all if even
the lowest setting would be over. With a 3 dBi antenna and 12 dB of amplifier gain that is 14 at
869.4 to 869.65 MHz and 1 at 868.0 to 868.6 MHz. The firmware applies it whenever the frequency
changes and ignores any higher setting from the app, MeshCore's console or a command. MeshCore's
default for the V4 (10, about 22 dBm out) is inside the 10% band's limit and over the 1% band's.

MeshCore also keeps its own transmit budget (`Dispatcher`, `getAirtimeBudgetFactor`). Help&I's
budget is on top of it and does not replace it.

## 9. The clock

Frames carry wall-clock times: a call's press time, which responders' phones use to count
escalation from the press, and an acknowledgement's time, checked against the press. A Heltec has
no clock battery. The box gets the time from the phone whenever it connects and keeps it while it
has power. After a cold start with no phone, MeshCore already sets its clock to just after the
newest time saved in flash (`bootstrapRTCfromContacts`).

A press time that is too early only makes responders' phones escalate sooner. One that is too
late would delay their alerts. So the box must never claim a later time than the true one: it uses
the newest time it can justify, and only raises it from the phone, or from a frame signed by a
current member (an acknowledgement, a membership repeat), never from unsigned traffic.

## 10. Power cuts and battery (decisions 3 and 4)

Not in the core yet, because the message needs a decision first.

- Mains loss: the mains pin going low for more than, say, 10 seconds (so a flicker is not a
  power cut). With the person's opt-in, the box tells the responders. Mains back is reported
  the same way.
- Battery: hours left estimated from the battery's voltage curve and the box's measured average
  draw, reported at 24, 12, 6, 3, 2 and 1 hours. A responder's acknowledgement of the power cut
  silences all but the final warning (decision 4).

The frame is the question. CallCategory already has `powerCut`, but every category except a
missed check-in is personal and goes sealed for responders, which needs the responders' sealing
key on the box (X25519, HKDF-SHA256 and ChaCha20-Poly1305: MeshCore's `rweather/Crypto`
dependency has all three, so it is possible). The alternative is a new plain frame with only the
unit number, mains state and hours left, numbered like a request so the existing signed
acknowledgement silences it. Open question below.

## 11. How it sits on MeshCore

- `firmware/core`: the portable logic, plain C++17, no Arduino, no heap, no exceptions.
- Later, `firmware/box`: a PlatformIO project that builds MeshCore's companion firmware at a
  pinned commit with a Help&I UI task in place of `ui-new`, the pins above, and the core.
  The UI task reads the buttons every 5 to 10 ms into `ButtonMachine`, turns its events into
  calls, sounds and the screen, receives Help&I datagrams through `onChannelDataRecv`, and sends
  through `sendGroupData` with data type `0xFF48`.
- New companion commands, in a range MeshCore does not use, for provisioning (section 6) and for
  the box telling its phone about its own calls. The app would need to recognise a Help&I box
  (from DEVICE_INFO's model and version) and carry the box's calls on its own routes. That is app
  work, not started.
- Register a MeshCore data type before release (TODO.md, MeshCore data_type): MeshCore's
  `docs/number_allocations.md` says to show a working project first, then ask.

## 12. The portable core in this folder

| File | What | Follows |
|---|---|---|
| `core/frame.hpp` | Encode and decode the call (kind 1), acknowledgement (3), call state (0x22) and signed (10) frames; build the bytes each signature covers; which frames may go on the group channel | HelpFrame.swift |
| `core/call.hpp` | The resend schedule, a call's status, acknowledgements, settling, I'm OK, close repeats | Resend.swift, Requests.swift, Engine.swift |
| `core/airtime.hpp` | Time on air, the UK bands, the hourly budget, the transmit power cap | Airtime.swift |
| `core/buttons.hpp` | Debouncing, press, long press, the countdown and stopping it | HelpCountdown.swift, the watch |

Run the host tests from `firmware/`:

```
make test
```

That builds with `c++ -std=c++17 -Wall -Wextra -Werror -pedantic` and the address and
undefined-behaviour sanitisers, and runs every test.

**Where the core differs from the Swift code on purpose.**

- The decoder rejects trailing bytes after a call state. HelpFrame.swift checks for trailing
  bytes on the 16 nibble kinds but not after 0x21, 0x22 or 0x23. Swift never writes any, so this
  changes nothing for frames the app sends.
- The encoder refuses a reason over 56 bytes, or not UTF-8, rather than cutting it. Swift cuts at
  a character (grapheme) boundary, which this core cannot reproduce without Unicode tables; the
  box never sends a reason.
- The encoder refuses a signed frame whose inner frame is over 80 bytes rather than cutting it
  (which would also break the signature).
- For a header byte it does not read (a follow-up, a sealed note, settings), the decoder says
  "other" without checking the rest, so the box can pass it to the phone unread. The phone then
  applies its own checks.
- Packet size and preamble, as in section 8.

**Test vectors.** Swift could not be run here, so the vectors in `test/frame_tests.cpp` were
worked out by hand from `HelpFrame.encoded()`, field by field, and checked with a separate
script. They use the same values as HelpFrameTests.swift so they can be confirmed from the Swift
side by adding the same byte arrays there. Where unsure: Foundation's UTF-8 check on odd input
(the core follows RFC 3629 strictly), and whether CryptoKit's signatures verify with MeshCore's
Ed25519 library (no signature vectors here: none could be made from a phone).

## 13. Test plan

**Host tests (built, run, passing).** 45 tests in `firmware/test`: the frames byte for byte
against the Swift layout, malformed and stray input, what may go on the group channel, the
signature inputs; the resend times, acknowledgement rules, removal, settling and close repeats;
airtime against Semtech's figure, both bands, the budget's shares, reservations and a full log;
the power cap; debouncing, a button held at start-up, press and long press, the countdown's taps,
warning and Help, a late wake, and stopping it. Still to add when the code exists: Ed25519
checks with a vector from a real phone, provisioning, and an end-to-end test of the Help&I UI
task against a fake radio.

**Proposed new sections for `tests/MANUAL-TESTS.md`** (not added there; they apply only once
Help&I firmware exists, and replace "Help&I needs no firmware of its own" in Before you start).

> ### 45. The box's buttons with no phone
>
> Needs two boxes with Help&I firmware, provisioned into the same group, and phone B as a
> responder with its own box. Switch phone A off.
>
> 1. On box A, press red once, briefly.
> 2. Hold red down for ten seconds.
> 3. On phone B, acknowledge.
>
> Pass: box A beeps once and shows "Sending", then "Sent. Waiting for someone to see it.", and
> never anything that suggests help is on its way. Phone B alerts within a few seconds. Holding
> red makes no second call (phone B's list shows one). Only after step 3 does box A show that a
> responder has seen the call, with its "seen" sound.
>
> ### 46. The cross on the box
>
> 1. Take box A's antenna off, or set box A to a frequency outside the UK bands, and press
>    amber.
>
> Pass: box A shows a cross and "Not sent. Nobody may know you need help. If you need help now,
> call 999.", with its cross sound. With the frequency outside the bands it sends nothing at all
> (check with a third board).
>
> ### 47. Resends from the box until someone acknowledges
>
> 1. Switch phone B's box off. On box A, press red.
> 2. After two minutes, switch phone B's box on. Do not touch box A.
> 3. On phone B, acknowledge.
>
> Pass: phone B alerts within ten minutes of step 2. Box A shows "seen" only after step 3, and a
> third board's log shows box A's repeats stopping after it.
>
> ### 48. I'm OK on the box
>
> Run once with the box's profile set to "I'm OK closes the call" (A) and once to "stops the
> urgent repeats" (B).
>
> 1. On box A, press red, then green.
>
> Pass: phone B shows the call and then I'm OK, quietly. In A the call shows as closed by the
> caller; in B it stays open until a responder acknowledges. In B, box A's repeats carry I'm OK.
>
> ### 49. Bouncing, stuck and start-up presses
>
> 1. Tap red as lightly and quickly as you can, ten times.
> 2. Hold red while plugging box A in, keep holding for ten seconds, then let go.
> 3. Press red once.
>
> Pass: in step 1 each tap that beeps makes exactly one call and none makes two. Step 2 makes no
> call. Step 3 makes one.
>
> ### 50. The countdown on a plain Heltec (development layout)
>
> 1. On a board with only PRG, press PRG briefly, and do nothing for a minute.
> 2. Press PRG briefly, then press it again after a few seconds.
> 3. Hold PRG for three seconds.
>
> Pass: step 1 counts down from 60 on the screen, beeping every 10 seconds if a buzzer is fitted,
> shows the warning at 30 seconds left, and sends Help at 0. Step 2 stops the countdown and sends
> nothing. Step 3 sends I'm OK.
>
> ### 51. Sounds and screen for someone with poor sight or hearing
>
> Pass: the press, "seen" and the cross each have a sound that can be told apart from the others
> across a room, and none is harsh. The screen's words can be read at arm's length. The LED
> shows the state in a dark room.
>
> ### 52. A power cut
>
> 1. With box A on its mains adapter and battery, and the person's power-cut report turned on,
>    switch the adapter off at the wall for one second, then on.
> 2. Switch it off and leave it off.
> 3. On phone B, acknowledge the power cut.
>
> Pass: step 1 reports nothing. In step 2 phone B hears that unit's power is off within a
> minute, then battery reports at the agreed hours; red still works throughout. After step 3 only
> the final battery warning still comes. With the report turned off, nothing is sent in step 2.
>
> ### 53. Battery life on battery alone
>
> 1. Charge box A fully, unplug it, and leave it idle, pressing red once an hour.
>
> Pass: it runs at least 24 hours, every press is heard, and its hours-left estimates are within
> an hour of the truth near the end.
>
> ### 54. Transmit power and duty cycle
>
> Needs an RF power meter or a calibrated spectrum analyser.
>
> 1. Measure box A's output at each band with its own antenna's rated gain set.
> 2. Press red, amber and green repeatedly for an hour.
>
> Pass: output is within the band's ERP limit with the antenna's gain. In step 2 the box's own
> sending stays under the band's duty cycle, and red still goes out after amber and green have
> used their share.
>
> ### 55. The box and its phone together
>
> 1. With phone A connected to box A and the internet on, press red on the box.
>
> Pass: phone B hears the call once, whether by the mesh or the internet, and box A shows "seen"
> after B acknowledges, by either route.

## 14. Open questions for Martin

1. **The firmware decision itself**: A (Help&I firmware on MeshCore, recommended), C (a hub) or
   B (stock, phone-dependent buttons, which AGENTS.md rules out). A or C means revising decision
   8's "with nothing added".
2. Can Help&I commit to tested firmware releases, and to a way of updating boxes in people's
   homes (over Bluetooth from the app, say)? If not, C.
3. The box as its own member with its own unit (recommended), or acting for one person's unit?
4. Reuse MeshCore's board identity key for Help&I signatures (one key, different signed
   prefixes), or make a second key just for Help&I?
5. May the box hold responders' names, so it can say who has seen the call? Recommended: no, it
   says "a responder"; names stay on phones.
6. A second press of red while a call is open: a new call (as the app does), or the open call
   sent again at once?
7. The plain-PRG development layout: a 60-second countdown (the watch's) or shorter?
8. After a cold start with no record of the last hour, count the optional half of the airtime as
   used for an hour?
9. Power-cut and battery reports: sealed for responders like other choices, or a new plain frame
   carrying only the unit number? And is a power cut at someone's home personal?
10. Flash encryption and secure boot on boxes that go to homes?
11. The antenna each box ships with, and its gain, so the power cap can be set.

## 15. Things in the Swift sources that look inconsistent

For whoever works on `app/helpandeyeCore`; nothing here was changed.

1. `meshPacketBytes` (Airtime.swift) leaves out the length byte MeshCore puts before a group
   datagram's payload, so it counts a block short for payloads of 14, 30, 46... bytes (section 8).
2. `RadioSettings` defaults to a 16-symbol preamble; MeshCore uses 32 at SF8 and below, which
   includes the UK narrow preset the tests use (section 8). Both make the app count less airtime
   than it uses.
3. `HelpFrame.init` checks for trailing bytes on the nibble kinds but returns early for 0x21,
   0x22 and 0x23 without that check, so a call state with junk after it is accepted.
4. `HelpFrame.signed` encodes at most 80 bytes of the inner frame, but `signing` signs the whole
   inner frame, so an inner frame over 80 bytes would go out with a signature that cannot verify.
   No frame signed today is that long, as far as could be seen.
5. A `.note` built directly, not through `HelpFrame.note(typed:)`, is cut at 120 bytes, which can
   split a character and make a frame its own decoder rejects as not UTF-8.
6. `OutgoingRequest.nextResend` gives a time for an I'm OK call after its four repeats, though
   `resendDue` will never be true again for it.
7. The watch numbers its calls from 32768 and the phone from 1, which uses the whole request
   number range; a box acting for the same unit would have no numbers of its own. The box as its
   own member avoids this.
8. ForResponders' nonce puts unit and request in big-endian, while every frame is little-endian.
   Not wrong, but worth a comment for anyone reimplementing it on a board.
