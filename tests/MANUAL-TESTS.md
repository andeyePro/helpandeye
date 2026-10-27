# Manual tests

Checks that need eyes, ears or hands. Run the relevant sections on real hardware before a pull
request is merged, and record the commit you tested.

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

Pass: each phone says "Connected. Calls can go over the local radio.", shows a frequency of 869.618 MHz and the band "869.4–869.65 MHz, 10% of the time", and a box battery voltage. Repeat with a board set to a frequency outside the UK bands: the phone must say it will not send on it.

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
