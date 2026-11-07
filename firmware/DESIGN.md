# Help&I box firmware: design

**Status: decided and built, untested on hardware.** Martin chose option A on 2026-10-30
(section 14). The firmware compiles for the Heltec WiFi LoRa 32 V4 (`firmware/build.sh`) and the
portable core passes its host tests on a Linux PC. Nothing in `firmware/` has run on a board:
every board section of `tests/MANUAL-TESTS.md` is still to be run. Until a box has passed them
the prototype keeps MeshCore's stock companion firmware.

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

## 3. Decision: A (Martin, 2026-10-30)

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

A revises decision 8. Where it says the box is a standard Heltec LoRa board "with nothing
added", it now has buttons, a buzzer and mains sensing added, and runs Help&I's own build of
MeshCore's companion firmware; the rest of the decision (the routes, the phone, a SIM later)
stands. The wording for `docs/design-decisions.md`, whose owner makes the change, is in section
14.

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
- **An LED** for the box's state where the screen cannot be seen (dark room, poor sight). It
  also tells whoever is setting the box up that its Bluetooth is off for want of a screen and a
  label code (section 6).
- **Battery sensing**: already on the board. `PIN_VBAT_READ` is GPIO 1, switched by
  `PIN_ADC_CTRL` (GPIO 37); `HeltecV4Board::getBattMilliVolts` reads it.
- **Mains sensing**: a divider (say 100 kΩ over 100 kΩ) from the board's 5 V pin, which carries
  USB power, to a GPIO. With the box on a mains USB adapter, 5 V present means mains is on. A
  power bank or UPS between the adapter and the box would hide a power cut, so the setup
  instructions must say to plug the adapter straight into the wall. A box built without the
  divider (`HI_MAINS_SENSED=0`) estimates mains from the battery's
  trend instead (section 10), later and with less confidence; the wire wins when a build has it.
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

**No screen: the label code (Martin, 2026-11-02).** MeshCore's companion picks a random code at
each start only when its screen started; without one it falls back to the build's fixed code,
123456, so anyone in range could pair with a box whose screen had failed and set it up for their
own group or wipe it (Forget, 0x75). Martin's decision: each box gets its own pairing code, made
at provisioning and printed on a label, used when its screen fails. The box makes it at its first
set group (0x71): six digits from the chip's random generator, 100000 to 999999 and never 123456
(`labelCodeFrom` in `core/box.hpp`, host-tested), kept in NVS with the names (encryptable,
section 16) and given to the phone in every info reply (0x70) from then on, so the app that
provisioned the box can show it for the label. Nothing is baked into the firmware and no new
command is needed. At every start the rule is `pairingAtStart` (`core/box.hpp`, host-tested
for every case): a working screen shows MeshCore's fresh random code as before and the label
code is not used; no screen and a label code, and Bluetooth starts with the label code
(`AbstractUITask::pairingCode`, beside `allowsBluetooth` in `meshcore.patch`, gives MeshCore the
code to start with); no screen and no label code, and the box starts no Bluetooth at all, neither
advertising nor accepting a companion connection (`allowsBluetooth`, the second hook, asked
before the interface starts, which is then never registered, so nothing can switch it on later).
A code the phone stored with MeshCore's own command makes no difference without a screen. Forget
clears the label code with the rest, so a box given to a new group gets a new code and a new
label at its next set group; until then, with no screen, it is back to no Bluetooth, which is
also where a box that was never provisioned stands. Everything the buttons need carries on as
usual whatever Bluetooth does: the buttons, buzzer, LED and radio, the group and members already
in flash, resends and acknowledgements. A box with neither screen nor label code loses its
phone: no setting up, no updates to the member list or names, no carrying of its calls on the
phone's routes, and no Forget, until the screen is mended. It is decided again at every start,
so a box whose screen works after a restart has Bluetooth again with a fresh random code on the
screen. To tell whoever is setting such a box up why no phone finds it, the state LED gives two
short flashes every two seconds while the box is awake (the two minutes after starting or a
press, when the screen would be lit) and no call is open; an open call keeps its own steady or
blinking light (`ledLit`, host-tested). With the label code in use the LED does not flash: a
phone finds the box as usual. The label is a secret: a phone paired with the label code can do
what any paired phone can, and set group (0x71) and Forget (0x75) need no group key, so whoever
has read the label can set up a box whose screen has failed for their own group or wipe it. The
label belongs on the box's underside or inside its lid, not where a visitor reads it. Until the
app shows the code from the info reply (TODO.md), a box provisioned on this firmware holds a code
nobody has read: if its screen then fails it advertises with that code and the LED does not
flash, and the box has to be set up again once its screen is mended. The code is made before the
group file is written, so a set group whose file could not be saved (ERR 5) leaves the code for
the phone's retry.

**The box as its own member (Martin, 2026-10-30).** The box joins the group as a caller in its
own right, with its own unit number, like a person who only calls. Its key is made on the board
and never leaves it: MeshCore's own identity, an Ed25519 key, reused for Help&I signatures
(Martin, 2026-10-30; one key, different signed prefixes). The same key seals: MeshCore's private
key is SHA-512 of the seed, clamped, so its first 32 bytes are an X25519 scalar, and the box's
sealing key (the `sealKey` in its `memberAdded`) is that scalar's X25519 public key, which
`UITask::sharedSecret` uses with the responders' public key. The host tests do the same
derivation with TweetNaCl and open the result on the responders' side. A coordinator adds it with the usual
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
- The responders' public key (X25519), so it can seal a power-cut report for them.
- The antenna type the coordinator set for it, from which the box takes its transmit-power cap.
- Whether the person opted in to power-cut reports.
- The time (MeshCore's own `CMD_SET_DEVICE_TIME`).

What the box never gets: the internet group key (it has no internet route), any responder's or
the responders' private key, and anything personal.

**Names (Martin, 2026-10-30).** The box may hold responders' first names, so the screen can say
"Pat has seen your call." instead of "A responder has seen your call.". They come from the phone
as their own command, 0x76, not inside the member list (0x72): a name is optional where a key is
not, so a phone that sends no names, or Martin deciding against them, leaves 0x72 and the box's
wording exactly as today; names can be sent again without the keys; and 0x72's fixed 35-byte
entries and four-a-chunk layout stay as the app side will build them. A name is 1 to 16 bytes of
UTF-8, a first name only, never sent on air (`NameList` in `core/provision.hpp`). The box keeps
them in NVS, not in the SPIFFS files the group and members use, because NVS can be encrypted
under flash encryption and SPIFFS cannot (section 16). The screen names the first responder to
acknowledge the call, when the box holds a name its font can show (printable ASCII; an accented
name falls back to "A responder" rather than showing wrong letters); otherwise today's wording.
Forget (0x75) clears the names with the rest.

**The commands.** Help&I's companion commands sit where MeshCore's protocol has nothing: app to
box at 0x70 to 0x75, box to app at 0xA0 to 0xA3 (`core/provision.hpp`). Integers are
little-endian; keys are raw bytes; the reply to a command is MeshCore's own `OK` (0) or `ERR`
(1, then an error code: 6 for a bad argument, 5 when the box could not save it to flash), which
the app already reads. A set group, set members or set names the box could not save answers 5,
so the phone sends it again rather than marking it sent: the box goes by the new members and
names at once, but a restart would go back to the old ones, or, from a part-written members
file, to none.

| Byte 0 | Name | Body |
|---|---|---|
| 0x70 | info | nothing. Reply 0xA0: Help&I protocol version u8 (1), provisioned u8, unit u32, member u16, next request u16, mains u8 (0 unknown, 1 on, 2 off; plus 4 when estimated from the battery, section 10), battery mV u16, hours left u16, antenna u8 (as set by 0x71), power cap i8 (-128 when the box must not send), members u8, calls u8, the box's sealing key (32: the X25519 public key for its `memberAdded`; its signing key is MeshCore's own public key from `CMD_APP_START`), names u8 (how many first names the box holds, section 6), label code u32 (the box's pairing code for when its screen fails, section 6; 0 until its first set group), flags u8 (bit 0: the box's clock is ahead of a responder's phone, section 9; a reply that ends at the label code is from a build before the flags) |
| 0x71 | set group | 94 bytes after the command byte: group ID (16), member u16, unit u32, flags u8 (bit 0 I'm OK closes the call, bit 1 the caller may close, bit 2 report power cuts), antenna u8 (0 the V4's whip, 1 a stub, 2 an external 3 dBi, 3 an external 5 dBi, or 0x80 plus any antenna's gain in half-dB steps, 0 to 63.5 dBi, which is what the app sends, rounded up; 4 to 0x7F are refused), responders' public key (32, all zero when the group has none), channel secret (16), old channel secret (16, all zero outside a changeover), old secret ends at u32, first coordinator u16. The box's first set group also makes its label code, which the next 0x70 gives |
| 0x72 | set members | version u32, index u8, total u8, then up to four of: member u16, role u8 (1 caller, 2 responder, 3 both, 4 coordinator), Ed25519 signing key (32). Index 0 starts a new list; the list replaces the old one when every position up to `total` has arrived. At most 32 members |
| 0x73 | get calls | nothing. Replies 0xA1 per call: request u16, colour u8, pressed at u32, status u8 (0 sending, 1 waiting for a responder, 2 seen, 3 not sent, 4 closed), acknowledgements u8; then 0xA2 |
| 0x74 | route result | request u16, sent u8 (1 the phone's routes took it, 0 none did) |
| 0x75 | forget | nothing: the box leaves the group and clears its flash, names and label code included |
| 0x76 | set names | version u32, index u8, total u8, then up to eight of: member u16, length u8 (1 to 16), the first name in UTF-8. Chunked like 0x72: index 0 starts a new list, which replaces the old one when every position up to `total` has arrived; a total of 0 clears the names. At most 32 |
| 0xA3 | frame (push) | a frame the box made (its call, its signed I'm OK or close, a sealed report), for the phone to carry on its own routes and to show. The phone answers a call with 0x74 |

The box keeps the set-group and set-members bytes in flash as they came (`/hi_group`,
`/hi_members` on SPIFFS), the names as 0x76 chunks in NVS, its label code in NVS, and its next request number in NVS, written before each use. It puts
the group's channel (and the old one during a changeover) into MeshCore's own channel table
itself, at provisioning and at every start, since MeshCore decrypts group datagrams only for
channels it knows: the phone need not set the channel for the box to hear acknowledgements. Each
second it empties any other channel of its own in that table: the old one once the changeover
ends, and the previous group's after a new group or Forget. A phone
recognises a Help&I box from the firmware version MeshCore's device query returns
(`v1.18.0-hi1`), then sends 0x70. The app side is not built (TODO.md).

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

**Protecting the keys (Martin, 2026-10-30).** Boxes that go to homes get ESP32-S3 flash
encryption and secure boot, as long as they do not hurt uptime or adoption; development builds
do not. The trade-off: with them, someone who takes the box cannot read its key, the channel
secrets or (later) the names; without them, a box in a shared house is a readable copy of the
group's channel. Against: a box with secure boot takes only firmware signed with the project's
key, so a contributor cannot flash their own build onto it, a field update needs the signed
image and the signing key becomes something the project must guard, and a flash-encryption
mistake on a box in a home means a box that will not start. Both are set by eFuse on each box,
not in the build: `build.sh` makes a plain image, and `build.sh --release` signs and encrypts it
for the eFuse steps a person runs. Section 16 has the path, what it protects, what it does not
yet, and what is untested.

## 7. Calls, resends and acknowledgements on the board

Matching `Resend.swift`, `OutgoingRequest` (Requests.swift) and `checkResends` (Engine.swift),
in `core/call.hpp`:

- A press makes a call with the box's next request number, written to flash before it is sent,
  so a restart never reuses a number. With the box as its own unit, it numbers 1 to 32767 like a
  phone.
- The 12-byte call frame goes on the group channel at once, as urgent airtime.
- It goes again 30 s, 1, 2 and 4 minutes after the press, then every 10 minutes, until a person
  settles it: a valid acknowledgement, or a close. Nothing stops it on a timer. After a long
  sleep, missed slots are skipped, not sent back to back. Resends of Help and Need a hand use
  the resend share of the airtime, and I'm OK resends the optional share (section 8), so they
  never use up what a new press needs. A call the radio could not send is retried on the same
  times.
- An I'm OK call is repeated on the first four resend times, then left: after them it has no
  next resend time, as in `OutgoingRequest.nextResend`.
- While a call stands at I'm OK (profile B), the signed I'm OK goes with each resend, so a
  responder who missed both still comes to check.
- A close the box made is repeated on the call's resend times four times.
- An acknowledgement counts if it names this unit and request and carries the valid signature of
  a current member who can respond, whatever its time stamp (Martin, 2026-11-02: as resilient as
  possible; until then a box whose clock had run ahead refused every acknowledgement, so the
  caller never saw "seen" and the box kept resending). The same goes for a coordinator's signed
  close. The box checks the signature and membership before `OutgoingCall::receive`, which
  checks the numbers. The request number is the only guard against an old acknowledgement being
  replayed for a new call: the box holds a call for its number alone, and never reuses a number
  until it has used 32767, so a replay can match only after the numbers wrap, or after the NVS
  that holds the next number is erased and they start again at 1. An acknowledgement stamped
  more than five minutes before the press says the box's clock is ahead, which it tells the
  phone (section 9).
- What the box shows follows `CallerStatus`: sending, sent and waiting for a responder, seen,
  the cross (nothing could be sent by the box or by its phone), or closed. There is no
  "delivered": the radio sending is not a person reading it (decision 7). The words follow the
  app's ("Not sent. Nobody may know you need help. If you need help now, call 999."). A phone
  asked to carry a call that has not answered (0x74) by the call's first resend, 30 seconds on,
  counts as not having taken it, so a phone that went out of range, or an app that cannot answer
  yet, leaves the cross rather than "Sending..." for ever; its answer still counts if it comes
  later.

The core uses the board's monotonic clock for the schedule and the wall clock only for what goes
in frames, so the phone setting the time mid-call never moves a resend.

**I'm OK settles only what came before it.** A press of I'm OK settles the calls made before
it, never one made at the same moment or since, as `settleOnOK` in Engine.swift. The box compares
its monotonic times, so a clock set mid-call cannot change which calls it settles.

**Buttons** (`core/buttons.hpp`):

- A press counts once it has been steady for the debounce time (30 ms), and sends at once, not on
  release.
- I'm OK never goes while red or amber is held, in the same poll as either firing, or within
  3 seconds of either (`kNoOKAfterUrgentMs`), the countdown's Help included. Someone who falls on
  the box, or presses everything at once, sends Help and Need a hand, never I'm OK.
- After a cold power-on, a button already held counts only once it has been seen released, so a
  stuck button or one leant on while plugging in makes no call. The button that woke the board
  from deep sleep is different: the firmware passes the wake cause, and that press counts at
  once, even if the button was let go before the core first ran.
- A press during the countdown stops it, as on the watch: I'm OK then sends nothing, and Help or
  Need a hand go at once. A press that began before the end counts as during it, even when the
  debounce confirms it after.
- A late poll does everything missed. It keeps room for every call, stop and the countdown's
  Help; only taps and the warning of a long countdown can be left out when there is too much to
  report at once.

**Pressing again (Martin, 2026-10-30).** A second press of red while a call is open starts a
new call, as the app does. The box keeps its last eight calls; the oldest makes room for a ninth.

## 8. Airtime and transmit power

`core/airtime.hpp` follows `Airtime.swift`:

- Time on air per packet by Semtech's formula, explicit header and CRC on, low data rate
  optimisation when a symbol is over 16 ms.
- The two IR 2030 sub-bands MeshCore uses in the UK: 868.0 to 868.6 MHz (1%, 25 mW ERP) and
  869.4 to 869.65 MHz (10%, 500 mW ERP). Outside them the box sends nothing of its own.
- A one-hour sliding budget: new calls up to 90% of the legal allowance, resends of Help and
  Need a hand up to 70%, everything else (I'm OK resends included) up to 50%, so routine traffic
  never leaves an unanswered call no airtime. Airtime is reserved before sending and given back
  only if the radio refused the packet. An entry stamped later than now, after the clock went
  back, still counts: the budget never under-counts. The log has a fixed size; when it fills, the
  oldest entry is folded into the next one, which keeps it counted for longer, never shorter.
- Packet size as MeshCore sends it: `sendGroupData` puts the data type and a length byte before
  the payload, so the encrypted part is 3 + payload bytes, as `meshPacketBytes` in Airtime.swift
  now counts. On the board the time is the radio's own (`radio_driver.getEstAirtimeFor`, with
  the radio's real settings) for that packet plus the 4 bytes of transport codes MeshCore adds
  when a flood scope is set, which the box cannot see, so it is never short; rounded up
  (`UITask::airtimeMs`).
- The preamble MeshCore sends: 32 symbols at spreading factor 8 and below, 16 above
  (`RadioLibWrapper::preambleLengthForSF`), the default in both `RadioSettings`. At the UK narrow
  preset (SF8, 62.5 kHz) a 21-byte packet is 378 ms on air. The board can pass its own.

**After a restart (Martin, 2026-10-30).** The Swift budget is saved so a relaunch does not get a
fresh hour. A board that lost power has no record of the hour before, so after a cold start the
box counts the optional half of the hour's allowance as used (`BoxEngine::coldStart`): for that
hour, calls and their resends still go (their shares are 90% and 70%) and only I'm OK repeats,
closes and reports wait. The log is kept in the board's RTC memory with the rest of what the box
retains (section 10), so a plain reset or a wake from deep sleep carries the hour on; only a
start with no valid copy (a power-on, or another build) is a cold start.

**Transmit power.** `maxRadioPowerSetting` turns the band's ERP limit into the highest SX1262
setting, given the antenna's gain and the amplifier's gain, and refuses to send at all if even
the lowest setting would be over. The antenna's gain comes from the antenna type the coordinator
set in the app (Martin, 2026-10-30; section 6), which the app sends as the gain itself, so any
antenna can be set: the higher its gain, the lower the cap, and an antenna whose gain puts even
the lowest setting over the limit (above about 26 dBi at 869.4 to 869.65 MHz, 13 dBi at 868.0 to
868.6 MHz) stops the box sending: `BoxEngine` then refuses every packet of its own, calls,
resends, I'm OK, closes and reports alike, so a press shows the cross unless its phone carries
the call, and the firmware pulls MeshCore's setting down to the lowest. That lowest setting is
still over the limit, so the firmware also stops whatever MeshCore sends itself (a connected
phone's own traffic through the box, adverts, its replies on the mesh): `BoxEngine::antennaNotAllowed`
tells the UI task, which turns the radio's transmit path off (`RadioLibWrapper::setTransmitAllowed`,
the third hook in `meshcore.patch`, makes `startSendRaw` refuse every packet, which MeshCore's
dispatcher drops as a failed send). The box still listens. Its screen says "This box cannot send:
its antenna is not allowed. Ask your coordinator.", and a press shows the cross with "Not sent:
this box's antenna is not allowed. If you need help now, call 999."; a phone connecting reads
-128, must not send, as the power cap in the info reply (0x70). Outside the UK bands the antenna
is not what stops the box, and MeshCore's own traffic is not stopped. The app shows the same cap (`GroupState.maxRadioSetting`), and
both are tested against one table of gains. The V4's standard whip is assumed, at 2 dBi,
until measured; with 12 dB of amplifier gain that is 15 at 869.4 to 869.65 MHz and 2 at 868.0 to
868.6 MHz. The firmware applies the cap once a second (`UITask::applyRadio`), so a higher setting
from the app, MeshCore's console or a command is pulled back within a second. MeshCore's default
for the V4 (10, about 22 dBm out) is inside the 10% band's limit and over the 1% band's.

MeshCore also keeps its own transmit budget (`Dispatcher`, `getAirtimeBudgetFactor`). Help&I's
budget is on top of it and does not replace it.

## 9. The clock

Frames carry wall-clock times: a call's press time, which responders' phones use to count
escalation from the press, and an acknowledgement's time, which says whether the box's clock is
ahead. A Heltec has
no clock battery. The box gets the time from the phone whenever it connects and keeps it while it
has power. After a cold start with no phone, MeshCore already sets its clock to just after the
newest time saved in flash (`bootstrapRTCfromContacts`).

A press time that is too early only makes responders' phones escalate sooner. One that is too
late would delay their alerts. So the box must never claim a later time than the true one: it uses
the newest time it can justify, and only raises it from the phone, or from a frame signed by a
current member (an acknowledgement, a membership repeat), never from unsigned traffic.
`BoxEngine::heard` returns the time in a current member's validly signed acknowledgement (of any
unit's call) or signed call state when it is later than the box's clock, and the firmware sets
the clock to it; another unit's acknowledgement is checked only when its time is later. A member
whose phone's clock runs fast moves the box's clock on with it, as the phone setting the time
does.

**A bound on that raise (2026-10-31).** One member's signed time may raise the clock by at most a
day (`kMaxClockStep`). A time further ahead is held, not taken, until a different member's signed
time agrees with it to within a day: then two phones say the box's clock is the one that is
wrong, as after a cold start with no phone, and the box takes the earlier of the two. One phone
with its clock set days ahead cannot move the box's on. A phone a few hours fast still can, as the
phone that connects to the box can set its time directly; so the responders' phones count
escalation from the earlier of the press time and when they first heard the call
(`IncomingRequest.escalatesFrom`), and a call stamped ahead is alerted at once, not late.

**Telling the phone (Martin, 2026-11-02).** A box whose clock runs ahead, by up to a day on one
member's signed frame or by any amount from the phone that set it, takes every acknowledgement
all the same (section 7). It also knows: a responder's phone stamps its acknowledgement no more
than five minutes past its own clock (`ackTime` in Engine.swift), so one stamped more than
`kClockAllowance` before the box's own press time means the box's clock is ahead of that phone's.
The box records that (`BoxEngine::clockAhead`, host-tested, kept in the retained copy across a
reset) and the info reply (0x70) carries it as a flag, so the app can say so on the box's page
to whoever is paired, a coordinator included. The flag is cleared when the box's clock is set
back, which the app does at every connection, so a phone whose own clock is right clears it as
it connects and only a phone that is itself ahead goes on seeing it. Nothing on the box's screen
changes: it says a responder has seen the call once the acknowledgement counts, which is true.

**The monotonic clock across sleep and resets.** The core's schedule and airtime run on a
monotonic clock in milliseconds (section 7). On the board it is the 64-bit `monoMs()` (ESP-IDF's
microsecond timer, which never wraps) plus an offset (`UITask::now`). The retained copy (section
10) carries the clock it was taken at and the system time beside it; after a wake from deep sleep
the offset adds the time asleep, measured as the system time's advance, which ESP-IDF keeps
through deep sleep and nothing can set meanwhile (`resumedMonoMs`, host-tested). Both clocks are
read as the start begins, when the UI task is made: MeshCore's setup then sets the system clock
to just after its newest contact (`bootstrapRTCfromContacts`, at every start, a wake included),
which is usually earlier, and read after that the time asleep came out negative and wrapped to
thousands of years, emptying the hour's airtime record at every wake. A system clock behind the
copy's adds nothing. The UI task then puts the system clock back to the time it had through the
sleep, so a box asleep on battery does not fall back to its last contact's time at every wake.
After a plain reset the copy is at most a second old and the clock carries on from it, so the
retained calls' times and the airtime log's stamps stay in the past, never in the future.

## 10. Power cuts and battery (decisions 3 and 4)

A power cut at someone's home is personal, so the report is sealed for responders like any other
choice (Martin, 2026-10-30). `core/power.hpp` and `BoxEngine::power`:

- Mains loss: the mains pin low for 10 seconds (a flicker is not a power cut). With the person's
  opt-in and the responders' key on the box, the box tells the responders. Mains back is reported
  the same way. The screen's bottom line says "Power cut: about 12 h" (or "Power cut" before an
  estimate) whether or not it reports.
- Battery: hours left from the cell's resting voltage (a piecewise-linear curve from 4.2 V to the
  board's 3.4 V shutdown) and the box's average draw on battery, reported as the estimate passes
  24, 12, 6, 3, 2 and 1 hours. A responder's acknowledgement of the report silences all but the
  final warning, whatever its time stamp, as for a call (section 7); the cut's time is kept with
  the report across a reset, so one stamped more than five minutes before it still says the
  box's clock is ahead (section 9). The draw (`batteryModel`) is the deep-sleep draw (`HI_DRAW_ASLEEP_UA`) plus the
  awake draw (`HI_DRAW_AWAKE_MA`) for the share of each ten minutes the box is up to read the
  battery (about three seconds, `kAwakePerWakeMs`), rounded up to a whole milliamp so the
  estimate never flatters the cell; `HI_BATTERY_MAH` and both draws are build flags until section
  54 of the manual tests measures them. A call keeps the box awake, at the awake draw, for as long
  as it stands, and so does a connected phone: while either does, `BoxEngine::power` counts the
  hours at the awake draw (`PowerMonitor::setDraw`), and once the box is left alone again at the
  sleeping one. A report's own few minutes of repeats do not switch it. The marks are one-way, so
  a mark passed while a call kept the box up is reported then and not again.

**Deep sleep on battery.** MeshCore's companion build never sleeps on an ESP32: every pass of
its `loop()` runs the mesh (the SX1262 left in continuous receive, the outbound queue), the
Bluetooth serial interface (advertising whenever no phone is connected), the sensors, the UI
task and the clock; only its nRF52 build light-sleeps between passes. Awake, the V4 draws tens
of milliamps, which is what `HI_DRAW_AWAKE_MA` stands for, and decision 4's day on battery
would need a large cell. So on battery the box deep-sleeps whenever nothing needs it awake. The
core decides (`BoxEngine::canSleep`, host-tested): the mains have been off for the ten seconds
(on mains it never sleeps, and never while the mains are not yet known), no call is still being
resent (a Help or Need a hand nobody has acknowledged, or one the radio could not send, is
resent until a person settles it, so the box stays up for it; an I'm OK is left after its four
repeats), no close or report is still being repeated, and no phone is connected (the box is that
phone's radio). The UI task adds what only it knows: nothing queued for the radio or on air
(`hasPendingWork`, `isInRecvMode`), no countdown, no sound playing, and the screen's two
minutes after a press over.

Going to sleep (`UITask::sleep`, after the board's own `enterDeepSleep` and `powerOff`, which
cannot be called because they clear every wake source), the box puts the SX1262 to sleep and
holds its chip select, switches the amplifier's supply off, turns the screen off (and with it
Vext) and sets the wake sources, with the RTC peripherals left powered so the pull-ups hold: the
three buttons through EXT1, any low (PRG on a plain board; all RTC pins, section 5); the mains
pin through EXT0, high, so mains returning wakes it; and a timer of ten minutes (`kSleepS`) to
read the battery. Waking, MeshCore starts as from power-on. The UI task gives `ButtonMachine`
the buttons that woke it (`esp_sleep_get_ext1_wakeup_status`), so the waking press counts even
if it was let go in the second the board took to start; resumes the retained copy (below); and
after a timer wake keeps the screen dark and sleeps again as soon as the battery has been read,
unless a mark has passed and its note's repeats keep it up. Bluetooth advertises again at every
wake (when the screen started, section 6), so a phone nearby may see the box come and go; one that connects keeps it awake.

**What a sleeping box misses.** Deep sleep stops the radio, so a sleeping box hears nothing:
calls from others (this is a caller's box, not a responder's; it never answers them),
acknowledgements (none can be due: it sleeps only with no call open), a coordinator's close
(nothing open to close), and the signed membership repeats. A removal it misses is applied when
its phone next sends the member list; until then a removed responder's acknowledgement would
still count on this box. That is the trade-off taken for the battery: the person's own call is
what the box is for, and every one of them keeps it awake until a person settles it.

**What survives** (`BoxEngine::retain`, `resume`; `kRetainedBytes`, two copies of about 4 KB).
The hour's airtime log, the power monitor (so a wake is not a new power cut and the hour marks
are not reported again), the eight calls, the open report's number and part count, and the two
clocks it was taken at (section 9), as the struct's own bytes with a checksum, a layout number
and a sequence number, in RTC slow memory (`RTC_NOINIT_ATTR`, which a reset leaves alone and a
power-on leaves as it was), written every second while awake and again before sleep. Each write
goes over the older of two copies, so a reset in the middle of one leaves the other whole, a
second older; a start resumes from the newest copy the checksum and layout confirm. With neither
confirmed it is a cold start (decision 8): a power-on, or another build. The two copies take
7936 of the ESP32-S3's 8192 bytes of RTC slow memory (the airtime log's entries are packed to 16
bytes to fit), checked at compile time in `UITask.cpp`. What the copy cannot know stays as the start has it: the band's
duty cycle (the radio's settings may have changed in the second before a reset) and the build's
battery and mains wire (a firmware update keeps the copy when the layout is unchanged). A report's
remaining repeats are not kept, so a reset during them loses the rest; the next mark makes the
next note.

**Without the mains wire (Martin, 2026-10-30).** A build with `HI_MAINS_SENSED=0` has no divider,
so `MainsEstimate` in `core/power.hpp` decides from the battery readings alone (the board reads
the cell once a minute). On mains the charger holds the cell near its charged level; when mains
goes the cell sags under the box's load and keeps falling; when mains returns the charger lifts
it, or holds a cell still too full to recharge. The estimate keeps two hours of readings and
compares five-minute means, so one noisy reading or a transmit burst cannot decide it:

- *Mains probably gone*: the newest mean at least 40 mV under the highest of the two hours, and at
  least 8 mV under the mean half an hour before it (still falling). A charger finishing, which
  steps the reading down and then holds it, and a full cell's slow self-discharge on mains, do
  not pass the second test, so a full cell resting never fires. A cut from a full cell shows
  about 20 to 30 minutes after it; a cut while the cell was charging, which loses the charging
  lift at once, within about ten.
- *Mains probably back*: the newest mean at least 25 mV over the lowest of the two hours (the
  charger), or half an hour of means within 6 mV of each other at 4.05 V or more (a cell held
  by its charger; on battery a cell that full falls through half an hour).
- Any verdict must hold for three minutes running before it counts, and nothing is decided in
  the first 35 minutes after a start. A box that starts on battery reports the cut once the
  fall shows; at half charge that can take an hour or more.
- Asleep on battery (below), the box reads the cell only at its ten-minute wakes, so the
  readings are ten minutes apart and mains back shows within about an hour and a half of the
  charger starting, not minutes. Without the wire there is no mains pin to wake it: the mains
  wake source is left off, so a floating pin cannot wake it either. The estimate's history is
  part of `PowerMonitor` and so of the retained copy (about 300 bytes of it), so a wake carries
  on from the readings before the sleep.

The thresholds are a guess at the Heltec V4's charger and the box's draw, to be set from a box's
own recordings (MANUAL-TESTS 53): the fall must stay above the step the charger makes when it
finishes, and the flat allowance below what a full cell loses on battery in half an hour. The
estimate reports with less confidence than the wire: `PowerMonitor::estimated()` is true, the
info reply's mains byte carries bit 2, `Screen::mainsEstimated` makes the screen's bottom line
"Power cut? about 12 h", and the report says so: after the power-cut follow-up comes a note,
"Power probably cut: the battery is falling.", and mains back is "Power probably back.".
Everything else, the hours, the marks and the acknowledgement, is the same as with the wire.

**The frames.** A report is a request of the box's own, numbered from the same counter as its
calls, so the responders' existing signed acknowledgement (kind 3) silences it and their phones
show it as a request from that unit; a follow-up for a request nobody has heard a call for already
makes one on a responder's phone (`Inbox.receive`). Each part is a `ForResponders` frame (kind
0) exactly as the app makes one: the inner frame, signed by the box (kind 10, signer the box's
member), sealed with ChaCha20-Poly1305 under the key HKDF-SHA256 derives from the X25519 secret
(salt the group ID, info `HELPA-RESPONDERS-1`), the nonce the unit and request big-endian, the
part, then five random bytes, and the group ID as the associated data.

| Part | Inner frame | Bytes of the inner frame |
|---|---|---|
| 1 | follow-up, category power cut | `12` unit u32 request u16 `01` `04` |
| 2, without the mains wire | a note, "Power probably cut: the battery is falling." | `16` unit u32 request u16 part u8 length u8 UTF-8 |
| then | a note as the hours pass: "About 12 hours of battery left.", "About 1 hour of battery left.", "Less than an hour of battery left." | `16` unit u32 request u16 part u8 length u8 UTF-8 |
| last | a note, "Power is back." ("Power probably back." without the wire) | the same |

On air each part is `10`, unit u32, request u16, part u8, the 5-byte salt, the sealed signed frame
and its 16-byte tag: 106 bytes for the power cut, up to 140 for a note, inside the 165-byte
datagram. A part goes once, then again at 30 seconds, 1, 2 and 4 minutes unless the report has
been acknowledged; the final warning goes regardless. The next power cut is a new request. The
host tests seal a report and open it as a responder's phone would, with the key derivation in
section 6.

## 11. How it sits on MeshCore

- `firmware/core`: the portable logic, plain C++17, no Arduino, no heap, no exceptions. It is
  copied into the MeshCore tree unchanged and compiled for the board.
- `firmware/box`: the overlay on MeshCore at the pinned commit. `ui-helpandi/UITask.{h,cpp}` is
  the Help&I UI task in place of `ui-new`: it owns a `ButtonMachine` (section 7) read every
  loop, a `BoxEngine` (`core/box.hpp`) it feeds with presses, time, the mains pin and battery
  voltage, and MeshCore's buzzer and screen. It receives Help&I datagrams through
  `onChannelDataRecv` (only on the group's channels) and sends through `sendGroupData` with data
  type `0xFF48`, signs with `self_id`, verifies with `mesh::Identity`, and seals with the core's
  own ChaCha20-Poly1305 (one implementation on the board and in the tests) over an X25519 secret
  from `Curve25519::eval`. `platformio.local.ini` adds two environments, `heltec_v4_helpandi`
  (the box: three buttons, buzzer, mains pin) and `heltec_v4_helpandi_dev` (a plain board,
  section 7's PRG layout). `meshcore.patch` is the one change to MeshCore's own files, four
  hooks: `Listener::onUnhandledCmdFrame`, so the UI task answers the Help&I companion commands;
  `AbstractUITask::allowsBluetooth` and `pairingCode`, asked in `main.cpp`'s setup before the
  Bluetooth interface starts, so a box with no screen starts it with its label code or not at
  all (all three section 6); and `RadioLibWrapper::setTransmitAllowed`, so a box whose antenna
  is not allowed transmits nothing at all (section 8). Every other UI task and firmware keeps
  MeshCore's behaviour: the hooks' defaults are yes and MeshCore's own code.
- `firmware/build.sh` clones MeshCore at the commit named in the script, copies the overlay and
  the core in, applies the patch and runs `pio run`. One MeshCore tree, reused. `--release` then
  signs and encrypts the images (section 16).
- The UI task passes the buttons that woke the board to `ButtonMachine` (section 7), keeps the
  core's retained copy in RTC memory and deep-sleeps on battery (section 10); the ESP32 calls are
  in `UITask::begin`, `keep` and `sleep`.
- The app's side is not started: recognising a Help&I box from the firmware version, sending
  0x71 and 0x72 at join and after every membership or settings change, carrying the box's calls
  (0xA3) on its own routes and answering with 0x74, and setting the antenna type (TODO.md).
- Register a MeshCore data type before release (TODO.md, MeshCore data_type): MeshCore's
  `docs/number_allocations.md` says to show a working project first, then ask.

## 12. The portable core in this folder

| File | What | Follows |
|---|---|---|
| `core/frame.hpp` | Encode and decode the call (kind 1), acknowledgement (3), call state (0x22) and signed (10) frames; build the bytes each signature covers; which frames may go on the group channel | HelpFrame.swift |
| `core/call.hpp` | The resend schedule, a call's status, acknowledgements, settling, I'm OK, close repeats | Resend.swift, Requests.swift, Engine.swift |
| `core/airtime.hpp` | Time on air, the UK bands, the hourly budget, the transmit power cap | Airtime.swift |
| `core/buttons.hpp` | Debouncing, press, long press, the countdown and stopping it | HelpCountdown.swift, the watch |
| `core/seal.hpp` | SHA-256, HKDF, ChaCha20-Poly1305, the responders' key and nonce, the sealed frame | ForResponders.swift |
| `core/power.hpp` | The ten-second mains rule, mains from the battery's trend without the wire, hours left, the six marks and the acknowledgement that silences them | decisions 3 and 4 |
| `core/provision.hpp` | The Help&I companion commands, the names and what the screen says with one, and the flash layout (section 6) | |
| `core/box.hpp` | The box: presses to calls, resends, acknowledgement checking, I'm OK and closes, removals, the changeover, the cold start and what survives a reset, when the box may sleep, the draw on battery, the power cap, reports, the screen, sounds and LED, Bluetooth at start | Engine.swift |

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
- An encoder given too small a buffer writes nothing into it, not the part that fits.

**Test vectors.** Swift could not be run here, so the vectors in `test/frame_tests.cpp` were
worked out by hand from `HelpFrame.encoded()`, field by field, and checked with a separate
script. They use the same values as HelpFrameTests.swift so they can be confirmed from the Swift
side by adding the same byte arrays there. Where unsure: Foundation's UTF-8 check on odd input
(the core follows RFC 3629 strictly), and whether CryptoKit's signatures verify with MeshCore's
Ed25519 library (no signature vectors here: none could be made from a phone).

## 13. Test plan

**Host tests (built, run, passing).** 139 tests in `firmware/test`: the frames byte for byte
against the Swift layout, malformed and stray input, what may go on the group channel, the
signature inputs, too small a buffer; the resend times, acknowledgement rules, removal, settling,
I'm OK settling only earlier calls, which share each resend uses, and close repeats; airtime
against Semtech's figure, the default preamble and packet size against EscalationTests.swift,
both bands, the budget's three shares, entries after a clock reset, reservations and a full log;
the power cap, and a box that must not send sending nothing and saying why; debouncing, a button held at start-up, the button that woke the board, press and
long press, all three pressed at once, falling on red and green, I'm OK just after Help, the
countdown's taps, warning and Help, a late wake, a 300-second countdown, and stopping it,
including by a press that began just before the end; the sealing primitives against their RFC
vectors and Poly1305 against TweetNaCl on every length, the nonce and the sealed frame's layout;
the mains rule, mains from the battery's trend alone (charging, a full cell resting for a
day, a cut from full and from half, the charger lifting the cell and holding one too full to
charge, a box started on battery, a sleeping box's ten-minute readings, a copied monitor, and
the wire overriding it all), the hours and the marks; the
provisioning bytes, the names in chunks, a cleared list, a malformed name and the screen's words
with and without a name; and the whole box against a
fake board with real keys (TweetNaCl, test only): a press, the resends, which acknowledgements
count, a removal, I'm OK under both profiles, the cross and the phone's routes, the bands and the
cold start, the power cap, a power-cut report opened as a responder's phone opens it, a
coordinator's close, the changeover, request numbers and forgetting; the retained copy through a
fake RTC store (the hour's airtime, the power cut and its part numbers and the calls carried on,
a corrupted or empty copy refused, the band and battery this start has kept over the copy's, the
clock carried through sleep and never wrapped, a write cut off part way resumed from the other
copy), a time more than a day ahead taken only when a second member agrees, when the box may sleep, the hours left with the box
asleep between polls, and Bluetooth at start (the screen's code, the label code, or none, and
the LED's flashes only for none; a label code's range and never 123456). Still to add: an acknowledgement signed by a real phone, checked on a
board.

**On a board** (not run): `tests/MANUAL-TESTS.md` sections 46 to 58, which replace "Help&I needs
no firmware of its own" in Before you start once a box has passed them. The sections proposed in
an earlier version of this file are there now.

## 14. Martin's answers (2026-10-30)

1. **The firmware decision**: A, Help&I firmware built on MeshCore's companion firmware, on the
   Heltec WiFi LoRa 32 V4 as the one standard unit, with the extra buttons on free header GPIOs
   (section 5). Decision 8 is revised accordingly; the wording for `docs/design-decisions.md`
   (its owner makes the edit): in decision 8, replace "with nothing added" with "with buttons, a
   buzzer and mains sensing added, running Help&I's own build of MeshCore's companion firmware
   (option A, firmware/DESIGN.md; Martin, 2026-10-30)".
2. Tested firmware releases and field updates: implied by 1; the update path is to be written
   up with the flash-encryption release step (section 6).
3. The box is its own group member with its own unit number.
4. Reuse MeshCore's board identity key for Help&I signatures.
5. **Names on the box: yes, behind a flag.** First names come from the phone as command 0x76,
   kept in NVS, and the screen says "Pat has seen your call."; a phone that sends none leaves
   today's wording (section 6). Martin may still say no: then the app simply never sends 0x76.
6. A second red press while a call is open starts a new call, as the app does.
7. The development layout with only PRG: a press starts a 60-second countdown, a second press
   stops it, as on the watch.
8. After a cold start with no record of the last hour, the optional half of the airtime counts as
   used for an hour. (Now that the record survives a reset and deep sleep in RTC memory, a cold
   start is a start with no valid copy there: a power-on, or another build; section 10.)
9. Power-cut and battery reports are sealed for responders like other personal content; a power
   cut at a home is personal.
10. Flash encryption and secure boot on boxes that go to homes, as long as they do not hurt
    uptime or adoption; the trade-off is in section 6; not in development builds. The release
    path is section 16.
11. Assume the V4's standard whip for now. The coordinator sets each unit's antenna type in the
    app and the box takes its transmit-power cap from it (sections 6 and 8); the app side is
    separate work.

## 15. Things in the Swift sources that look inconsistent

For whoever works on `app/helpandeyeCore`; nothing here was changed. The packet size (the length
byte), the 32-symbol preamble and `nextResend` for I'm OK after its four repeats, once listed
here, were fixed in the app in commit a9f5267, which also gave resends their 70% share.

1. `HelpFrame.init` checks for trailing bytes on the nibble kinds but returns early for 0x21,
   0x22 and 0x23 without that check, so a call state with junk after it is accepted.
2. `HelpFrame.signed` encodes at most 80 bytes of the inner frame, but `signing` signs the whole
   inner frame, so an inner frame over 80 bytes would go out with a signature that cannot verify.
   No frame signed today is that long, as far as could be seen.
3. A `.note` built directly, not through `HelpFrame.note(typed:)`, is cut at 120 bytes, which can
   split a character and make a frame its own decoder rejects as not UTF-8.
4. The watch numbers its calls from 32768 and the phone from 1, which uses the whole request
   number range; a box acting for the same unit would have no numbers of its own. The box as its
   own member avoids this.
5. ForResponders' nonce puts unit and request in big-endian, while every frame is little-endian.
   Not wrong, but worth a comment for anyone reimplementing it on a board.

## 16. Release: flash encryption and secure boot

For boxes that go to homes (Martin, 2026-10-30; section 6). Nothing here has run on a board.

**What the toolchain gives.** PlatformIO's espressif32 platform (6.11.0) builds Arduino-ESP32
2.0.17 from prebuilt libraries: their `sdkconfig` for the ESP32-S3 has `CONFIG_SECURE_BOOT`,
`CONFIG_SECURE_FLASH_ENC_ENABLED` and NVS encryption all off, and the bootloader is prebuilt the
same way. So no build flag turns either feature on, and `platformio.local.ini` has none. What
the chip allows regardless: the images signed and encrypted on the host with esptool's
`espsecure.py`, the keys and settings burned into eFuses with `espefuse.py` (both in PlatformIO's
`tool-esptoolpy` package, 4.5.1), and the encrypted images written with `esptool.py`. The ROM
then checks the bootloader's signature and decrypts flash as it reads it.

**Keys.** Made once with `espsecure.py`, kept in a directory outside every repository (on
Martin's machine, with an offline backup), never in git, named to `build.sh` as
`HI_RELEASE_KEYS`:

```
espsecure.py generate_signing_key --version 2 --scheme rsa3072 secure_boot_signing_key.pem
espsecure.py generate_flash_encryption_key --keylen 256 flash_encryption_key.bin
```

The signing key is the project's one. Give each box its own flash key (a directory per box,
each with the one signing key and its own `flash_encryption_key.bin`): a key got out of one box
then opens no other, and `build.sh --release` is run once per box, since each image is
encrypted for its box. The project must keep every box's key for the box's life: a field
update over USB needs it (below).

**The build.** `firmware/build.sh --release [tree] [environment]` builds `heltec_v4_helpandi` as
it is, then signs `bootloader.bin` and `firmware.bin` for secure boot v2 and encrypts the four
images for the addresses they are flashed at (0x0 bootloader, 0x8000 partition table, 0xe000
`boot_app0`, 0x10000 app), into `.pio/build/<environment>/release/`. Without `HI_RELEASE_KEYS`
it builds and prints every step: a dry run. It never touches a board.

**Each box, by hand**, with the commands `build.sh --release` prints: write the four encrypted
images with `esptool.py write_flash`; burn the flash key (`burn_key BLOCK_KEY0 ...
XTS_AES_128_KEY`) and the signing key's digest (`burn_key_digest BLOCK_KEY1 ...
SECURE_BOOT_DIGEST0`); then in one `burn_efuse`: `SECURE_BOOT_EN`, the two unused digest slots
revoked, `SPI_BOOT_CRYPT_CNT 7` (flash encryption on for good), `DIS_DOWNLOAD_MANUAL_ENCRYPT`,
`DIS_DOWNLOAD_ICACHE`, `DIS_DOWNLOAD_DCACHE`, `DIS_DIRECT_BOOT`, `DIS_USB_JTAG`, `HARD_DIS_JTAG`
and `ENABLE_SECURITY_DOWNLOAD`. eFuses are one-way: a wrong one is a box to throw away, so the
first run is on a development board nobody needs (MANUAL-TESTS 59). The eFuse names were
checked against esptool 4.5.1's ESP32-S3 table; the set follows ESP-IDF's release-mode guidance
for the S3 and is to be read against the docs for the esptool version in use before the first
box.

**Field updates.** `release/firmware-signed.bin` is the signed app. Over USB, the box's secure
download mode still takes `write_flash`, so an update is that image encrypted for 0x10000 with
the box's flash key (what `build.sh --release` makes as `release/firmware.bin` for that box's
key directory) and written there. Over the air there is no route yet: this build does not
include MeshCore's OTA environment; when it does, the device encrypts what the OTA writes
itself, and the image to send is the signed one.

**What it protects, and what it does not yet.** With the eFuses burned, the app's code cannot be
read as code and a plain image will not run, the bootloader must carry the project's signature,
JTAG is off and USB reads of flash are refused. Not yet:

- *The app's signature is not checked.* The prebuilt bootloader was built without secure boot,
  so it boots any app that decrypts; keeping a replaced app out rests on flash encryption alone.
- *The keys and names are not encrypted.* Flash encryption covers the bootloader, partition
  table and app partitions only. MeshCore keeps its identity (the box's signing and sealing key)
  and contacts in SPIFFS, with the group file (channel secrets) and member list beside them, and
  SPIFFS cannot sit on an encrypted partition; the names, the label code (section 6) and the
  next request number are in NVS, which needs NVS encryption, not in the prebuilt core. Over USB they are unreadable once the
  eFuses are burned; with the flash chip taken off the board they are plain.

Both need an Arduino core built for it (`esp32-arduino-lib-builder`, or ESP-IDF with Arduino as
a component) with secure boot v2, flash encryption in release mode and NVS encryption on, and
the identity, group and members moved to NVS or to LittleFS on a partition flagged `encrypted`.
Until then the names should stay on the phone: the app side (TODO.md) should not send 0x76 to
a box in a home, and section 6's names are a feature behind that gate.

**Untested.** Everything on a board: that the signed prebuilt bootloader boots under secure boot
and reads encrypted flash (it was built without `CONFIG_SECURE_FLASH_ENC_ENABLED`; reads through
the cache should decrypt regardless); `boot_app0` and the OTA data under encryption; SPIFFS on a
chip with encryption on (its partition is not flagged, so plain reads should still work); the
eFuse set. The `espsecure.py` commands themselves could not be run on the build Mac: PlatformIO's
python there has no `cryptography` module (`python3 -m pip install --user cryptography` gives it
one). The dry run was run (`build.sh --release` without keys, which built the box image and
printed the steps).

