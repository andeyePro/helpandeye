# Manual tests

Checks that need eyes, ears or hands. Run the relevant sections on real hardware before a pull
request is merged, and record the commit you tested.

## Before you start

**Boxes.** Any Heltec WiFi LoRa 32 V3 or V4. Flash MeshCore's **Companion (BLE)** firmware, not the USB or Wi-Fi companion and not a repeater: plug the board into a computer, open the MeshCore web flasher (https://meshcore.io/flasher, linked from MeshCore's README) in Chrome or Edge, choose the board and Companion (BLE), and flash. Help&I needs no firmware of its own.

**Radio settings.** Set every box to the same UK preset, inside 869.40–869.65 MHz (or 868.0–868.6 MHz). Help&I does not change radio settings, and refuses to send on a box outside those bands; the Box tab shows the frequency and band. Use the preset your local mesh uses, set with MeshCore's own app or the flasher's console.

**Bluetooth PIN.** MeshCore's default pairing code is 123456 (MeshCore FAQ, 6.5). Pair with that the first time; Help&I then replaces it with a random six-digit code and shows it once in the Box tab. Write it down: pairing a phone again needs it.

**The app.** On a Mac with Xcode: `cd app && xcodegen generate && open HelpAndI.xcodeproj`. Choose your own team under Signing for both targets (HelpAndI and HelpAndIWatch), change the bundle identifier prefix if `org.andeye.helpandi` is taken in your account, and run on each phone. Allow Bluetooth and notifications when asked. Time-sensitive alerts and push need the matching capabilities in your team.

**Recording a run.** Note the commit (`git rev-parse --short HEAD`), the boards and firmware version, the phones and iOS versions, and which sections passed, failed or were skipped, in the pull request. A change made after your run voids it (AGENTS.md).

**Order.** Run sections 1 and 2 first: every other section needs a group and paired boxes. Then 3, 4 and 12 (the core promise: a call, the acknowledgement, the cross), then the rest in any order.

## Equipment

You need, unless a section says otherwise: two iPhones with the Help&I app (phone A for a caller,
phone B for a responder), two Heltec LoRa boards (v3 or v4) running MeshCore's standard companion
firmware set to the same UK radio preset (869.618 MHz), and one paired Apple Watch for section 7.
Keep both phones' internet off (aeroplane mode with Bluetooth on) unless a step says otherwise,
so the mesh is the only route.

## 1. Starting a group and joining in person

1. On phone B, tap Start a group, enter a group name and your name, leave "I may also call for help" off, and start it.
2. On phone B, open Group, tap Invite someone. A QR code appears.
3. On phone A, tap Join a group and scan it. Enter a name, leave "I may call for help" on, tap Next. A second QR code appears.
4. On phone B, scan phone A's code. Check the name is right and tap Add them. A welcome code appears.
5. On phone A, scan the welcome code.

Pass: phone A shows the Help, Group and Box tabs; phone B lists phone A's person as "Calls for help, unit 70001". Both phones show the same group name.

## 2. Pairing the box

1. On each phone, open Box, tap Look for boxes, and tap your own board. Accept the Bluetooth pairing request and enter the PIN shown on the board.

Pass: each phone shows a new six-digit Bluetooth code under New Bluetooth code (the box had the default 123456), and after forgetting the box in iPhone Settings, pairing again needs the new code, not 123456. Each phone says "Connected. Calls can go over the local radio.", shows a frequency of 869.618 MHz and the band "869.4–869.65 MHz, 10% of the time", and a box battery voltage. Repeat with a board set to a frequency outside the UK bands: the phone must say it will not send on it.

## 3. A red call over the mesh, acknowledged by hand

1. On phone A, press Come now.
2. Watch phone A's status card.
3. On phone B, wait for the alert, open Respond, and do nothing for at least five minutes.
4. On phone B, tap Acknowledge.

Pass: phone A shows "Sending…", then "Sent. Waiting for a responder to see it." with "Local radio: sent", and never anything that suggests help is on its way. Phone B alerts within a few seconds with the caller's name and "come now". After five minutes the request is still at the top of phone B's list, unacknowledged. Only after step 4 does phone A show "<name> has seen your call."

## 4. The cross when nothing gets through

1. Switch off phone A's board (or forget it in Box).
2. On phone A, press Come when convenient.

Pass: phone A shows a cross and "Not sent. Nobody has been told.", lists why each route failed, offers Try again, and says "If you need help now, call 999." With a SIM in phone A, it also offers Send as a text, which opens a ready-written message naming no one.

## 5. Follow-ups arrive with their call

1. With both boards on, press Come now on phone A, then tap I've fallen and I feel unwell.

Pass: phone B shows one request, not three, with both details listed in the order they were tapped.

## 6. Escalation

Needs a third phone, C, joined as a responder.

1. On phone A, press Come now. Do not touch phones B or C.

Pass: one of B or C alerts at once and the other about two minutes later. Neither alert stops until someone taps Acknowledge on either phone. After one acknowledges, the other phone shows who acknowledged.

## 7. The watch

1. On phone A's paired watch, open Help&I and press Come now.

Pass: phone B alerts as in section 3, and the watch shows "Sent. Waiting for a responder." Put phone A out of the watch's range and press again: the watch shows a cross and tells the wearer to use their phone or call 999.

## 8. Removing a lost phone

Needs phone C from section 6.

1. On phone B (the coordinator), open Group, swipe left on phone C's person, and tap Remove.
2. On phone B, under New keys to hand out, show phone A its update code, and scan it on phone A under Key update.
3. On phone A, press Come now.

Pass: phone B alerts, phone C does not. Phone A's person still has the same unit number.

## 9. Availability and gaps

1. On phone B, open Group and tap I'm not available for the next 12 hours.

Pass: with phone B as the only responder, phone B's Group tab lists a gap covering the next 12 hours, and phone A's call alerts the whole group at once rather than waiting.

## 10. A request survives closing the app

1. On phone A, press Come now. On phone B, wait for the alert but do not acknowledge.
2. On phone B, swipe the app away in the app switcher, then open it again.

Pass: the request is still at the top of phone B's Respond list, unacknowledged, and can be acknowledged. Phone A's status card still shows the call after phone A's app is closed and reopened.

## 11. The box link recovers

1. With both phones connected, switch phone A's board off for a minute, then on.
2. On phone A, open Box and tap Forget this box.

Pass: after step 1, phone A shows "Connecting to your box…" while it is off and "Connected" again within a minute of it coming back, without touching the phone. After step 2, it shows "No box connected", not "Connecting…". A call pressed during step 1 shows "Local radio: not sent" with the reason, never "Sending…" for ever.

## 12. A call with no route at all

1. Forget the box on phone A, and leave the internet route unset.
2. Press Come now.

Pass: the cross and "Not sent. Nobody has been told." appear at once, not "Sending…".

## 13. Check-ins

1. On phone A, open Group, turn on Check in at set times, set the first check-in to two minutes from now with no second one, and tap Save.
2. Wait for the reminder notification and do nothing for 32 minutes.

Pass: the reminder arrives at the set time. About 30 minutes later (within a minute of that, with Help&I open) phone B gets a come-when-convenient call showing "Missed a check-in". Repeat, pressing I'm OK now when the reminder comes: phone B gets the green call and no missed check-in.

## 14. Typed messages and location

Needs the relay set up (Group, Internet route) on both phones, with internet on.

1. On phone A, press Come now, type "Back door is open" and tap Send, then tap Share where I am and allow location.
2. Turn phone A's internet off and try to send another message.

Pass: phone B shows the message in quotes and an Open their location in Maps link that opens near phone A. In step 2, with both boxes connected, the second message reaches phone B as a direct message between the boxes, cut to 96 bytes if longer. A third board on the same group channel, logging what it hears, never shows the text: it is encrypted to phone B's box alone.

## 15. Calls keep going until someone acknowledges

1. Switch phone B's board off. On phone A, press Come now.
2. After two minutes, switch phone B's board on. Do not touch phone A.
3. On phone B, acknowledge, then switch phone B's board off again for one minute, then on.

Pass: within ten minutes of step 2, phone B alerts for the call, although its board was off when the button was pressed. Phone A then shows "<name> has seen your call." If phone A did not hear the first acknowledgement in step 3, it still gets it: phone B sends it again when it hears the call repeated. Phone A stops sending once it has heard an acknowledgement (check with a third board's message log, or that phone B gets no more repeats).

## 16. A responder's alert repeats

1. On phone A, press Come now. On phone B, dismiss the notification without opening Help&I.

Pass: phone B alerts again about a minute later: once a minute for the first ten minutes, then every ten minutes, for red; every five minutes, then every half hour, for amber. It keeps going with phone B locked and Help&I closed for at least three hours (red). After an acknowledgement, no more alerts arrive, and the ones already showing are cleared. An "I'm OK now" alerts once, quietly, and does not repeat.

Known limit: over the internet route alone, with Help&I closed on phone B, alerts continue only as long as the notifications already scheduled, because the relay cannot wake the phone until push notifications are set up (TODO.md). Over the mesh, each repeat of the call wakes the app and tops them up.

## 17. A responder notices a missed check-in when the caller's phone is off

Needs the relay set up and internet on.

1. On phone A, turn on a check-in two minutes from now and tap Save. Wait a minute, then switch phone A off.
2. Wait 40 minutes.

Pass: about 35 minutes after the check-in time, phone B alerts "<name> missed a check-in" as a come-when-convenient call, which stays until someone acknowledges it. With phone A left on and pressing nothing, phone B gets phone A's own missed-check-in call and does not raise a second one.

## 18. Joining a second group

1. On phone B, leave the group, then join a different group that uses the same relay.
2. On a phone in the new group, press Come now.

Pass: phone B alerts. (A shared read position used to make it miss the new group's calls.)

## 19. A new responder's acknowledgement counts everywhere

1. With phones A (caller) and B (coordinator) in a group, add phone C as a responder (section 1, steps 2 to 5, on phones B and C). Do not show phone A anything.
2. On phone A, press Come now. Acknowledge on phone C.

Pass: phone A shows "Member <n> has seen your call." within a minute. Then remove phone C on phone B, press Come now again on phone A, and acknowledge on phone C: phone A must not show it as seen.

## 20. Acknowledging from a responder's watch

Needs phone B paired with an Apple Watch with Help&I on it.

1. On phone A, press Come now.
2. On phone B's watch, open Help&I.

Pass: the watch lists the caller's name and "Come now" with an Acknowledge button. Tapping it acknowledges exactly as on the phone: phone A shows "<name> has seen your call", and the entry leaves the watch. With phone B out of the watch's range, tapping it shows "Not acknowledged" and nothing is sent.

## 21. A missed check-in noticed with no internet at all

Like section 17, but with the internet off on every phone, so the mesh is the only route.

1. On phone A, turn on a check-in three minutes from now and tap Save. Wait a minute, then switch phone A off.
2. Wait 40 minutes.

Pass: phone B raises "<name> missed a check-in" about 35 minutes after the check-in time. A third board logging the group channel never shows the schedule: it went to phone B's box as a direct message.

## 22. Large text and VoiceOver

1. On phone A, set Settings, Accessibility, Display & Text Size, Larger Text to the largest size, and open Help&I.
2. Turn on VoiceOver and move through the Help tab, then press Come now.

Pass: every word on the Help tab can be read without cutting off; Come when convenient and I'm OK now sit one above the other rather than squeezed side by side. VoiceOver reads each button's name and what it does. After the press it says the status aloud ("Sending…", then "Sent. Waiting for a responder to see it."), and again when a responder acknowledges. Nothing on any screen depends on colour alone: every coloured button and dot also has words.
