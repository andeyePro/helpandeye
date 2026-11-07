# Manual tests

Checks that need eyes, ears or hands. Run the relevant sections on real hardware before a pull
request is merged, and record the commit you tested.

## Before you start

**Boxes.** Any Heltec WiFi LoRa 32 V3 or V4. Flash MeshCore's **Companion (BLE)** firmware, not the USB or Wi-Fi companion and not a repeater: plug the board into a computer, open the MeshCore web flasher (https://meshcore.io/flasher, linked from MeshCore's README) in Chrome or Edge, choose the board and Companion (BLE), and flash. Help&I needs no firmware of its own.

**Radio settings.** Set every box to the same UK preset, inside 869.40–869.65 MHz (or 868.0–868.6 MHz). Help&I does not change radio settings, and refuses to send on a box outside those bands; the Box tab shows the frequency and band. Use the preset your local mesh uses, set with MeshCore's own app or the flasher's console.

**Bluetooth code.** A Heltec V3 or V4 has a screen: MeshCore shows a fresh random pairing code on it each time the box starts, so pair using the code on the screen. A box without a screen uses MeshCore's fixed code, 123456 (MeshCore FAQ, 6.5); Help&I replaces that with a random code, keeps it, and shows it in the Box tab. The new code takes effect the next time the box is switched on.

**The app.** On a Mac with Xcode (install XcodeGen once with `brew install xcodegen`): `cd app && xcodegen generate && open helpandeye.xcodeproj`. Put your Apple team in `app/Local.xcconfig` first, as one line `DEVELOPMENT_TEAM = <your team ID>` (git ignores the file, and regenerating keeps it); all three targets then sign with it. The bundle IDs are `com.andeye.help`, `.notify` and `.watchkitapp`. Plug in the iPhone, choose it in Xcode and press Run; the first time, turn on Developer Mode in the iPhone's Settings, Privacy & Security. Allow Bluetooth, notifications and the camera when asked.

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

Pass: with a box that has a screen, pairing uses the code on the screen and the Box tab shows no code. With a box without a screen, the Box tab shows a six-digit Bluetooth code, still shown after closing and reopening the app; after switching the box off and on and forgetting it in iPhone Settings, pairing needs that code, not 123456. Each phone says "Connected. Calls can go over the local radio.", shows a frequency of 869.618 MHz and the band "869.4–869.65 MHz, 10% of the time", and a box battery voltage. Repeat with a board set to a frequency outside the UK bands: the phone must say it will not send on it.

## 3. A red call over the mesh, acknowledged by hand

1. On phone A, press Help.
2. Watch phone A's status card.
3. On phone B, wait for the alert, open Respond, and do nothing for at least five minutes.
4. On phone B, tap Acknowledge.

Pass: phone A shows "Sending…", then "Sent. Waiting for a responder to see it." with "Local radio: sent", and never anything that suggests help is on its way. Phone B alerts within a few seconds with the caller's name and "come now". After five minutes the request is still at the top of phone B's list, unacknowledged. Only after step 4 does phone A show "<name> has seen your call."

## 4. The cross when nothing gets through

1. Switch off phone A's board (or forget it in Box).
2. On phone A, press Need a hand.

Pass: phone A shows a cross and "Not sent. Nobody may know you need help.", lists why each route failed, offers Try again, and says "If you need help now, call 999." With a SIM in phone A and a mobile number saved by at least one responder (Group, Your mobile number), it also offers Send as a text, which opens a ready-written message naming no one, addressed to every responder with a number. With no responder number saved, Send as a text is not offered at all.

## 5. Follow-ups arrive with their call

1. With both boards on, press Help on phone A, then tap I've fallen and I feel unwell.

Pass: phone B shows one request, not three, with both details listed in the order they were tapped.

## 6. Escalation

Needs a third phone, C, joined as a responder.

1. On phone A, press Help. Do not touch phones B or C.

Pass: one of B or C alerts at once and the other about two minutes later. Neither alert stops until someone taps Acknowledge on either phone. After one acknowledges, the other phone shows who acknowledged.

## 7. The watch

1. On phone A's paired watch, open Help&I and press Help.

Pass: phone B alerts as in section 3, and the watch shows "Sent. Waiting for a responder."

Then, with the internet route set up (section 5) and the watch on Wi-Fi or its own mobile service:

2. Open Help&I on phone A once with the watch nearby, so the phone hands the watch the group. Then put phone A out of the watch's range (or switch phone A off).
3. On phone A's watch, press Help. On phone B, acknowledge.
4. Bring phone A back in reach of its watch and press Help on the watch again.
5. Now test a responder's watch: give phone B a paired watch, open Help&I on phone B once with it nearby, then switch phone B off. Press Help on phone A and acknowledge on phone B's watch.
6. Switch phone A off and press Help on its watch. Wait for the watch to show it sent, then switch phone A on, with its box connected and its internet off, and do not touch the watch. On phone B, acknowledge.
7. On phone A, leave the group.
8. Set phone A up in the group again, then put its watch out of reach. On phone A, leave the group and join another (start one on a spare phone if need be), with the watch still out of reach. Bring the watch back in reach, and press Help on a phone of the group it left.

Pass: in step 3 the watch says calls go over its own internet, phone B alerts, and the watch shows the acknowledgement only after phone B's person pressed it. In step 4 phone B shows one call, not two. In step 5 phone B's watch buzzes for the call (it does not buzz while phone B is on and alerting), and phone A shows the acknowledgement as phone B's. In step 6 phone A shows the watch's call within a minute of coming back, as "Sent. Waiting for a responder to see it.", then phone B's acknowledgement (which reaches it over the box); phone B shows one call, not two. After step 7 phone A's watch no longer calls or alerts for the group. In step 8 the watch does not alert for or list the call in the group it left, and Help on the watch reaches the new group. With no internet on the watch and its phone out of reach, the watch shows a cross and tells the wearer to use their phone or call 999.

## 8. Removing a lost phone

Needs phone C from section 6.

1. On phone B (the coordinator), open Group, swipe left on phone C's person, and tap Remove.
2. On phone B, under New keys to hand out, show phone A its update code, and scan it on phone A under Key update.
3. On phone A, press Help.

Pass: phone B alerts, phone C does not. Phone A's person still has the same unit number. Between steps 1 and 2, phone A's watch (if it has one, section 7) says on its second page to scan the new code on the phone by the date the phone shows; after step 2 the line goes.

## 9. Availability and gaps

1. On phone B, open Group and tap I'm not available for the next 12 hours.

Pass: with phone B as the only responder, phone B's Group tab lists a gap covering the next 12 hours, and phone A's call alerts the whole group at once rather than waiting.

## 10. A request survives closing the app

1. On phone A, press Help. On phone B, wait for the alert but do not acknowledge.
2. On phone B, swipe the app away in the app switcher, then open it again.

Pass: the request is still at the top of phone B's Respond list, unacknowledged, and can be acknowledged. Phone A's status card still shows the call after phone A's app is closed and reopened.

## 11. The box link recovers

1. With both phones connected, switch phone A's board off for a minute, then on.
2. On phone A, open Box and tap Forget this box.

Pass: after step 1, phone A shows "Connecting to your box…" while it is off and "Connected" again within a minute of it coming back, without touching the phone. After step 2, it shows "No box connected", not "Connecting…". A call pressed during step 1 shows "Local radio: not sent" with the reason, never "Sending…" for ever.

## 12. A call with no route at all

1. Forget the box on phone A, and leave the internet route unset.
2. Press Help.

Pass: the cross and "Not sent. Nobody may know you need help." appear at once, not "Sending…".

## 13. Check-ins

1. On phone A, open Group, turn on Check in at set times, set the first check-in to two minutes from now with no second one, and tap Save.
2. Wait for the reminder notification and do nothing for 32 minutes.

Pass: the reminder arrives at the set time. About 30 minutes later (within a minute of that, with Help&I open) phone B gets a Need a hand call showing "Missed a check-in". Repeat, pressing I'm OK now when the reminder comes: phone B gets the green call and no missed check-in.

## 14. Typed messages and location

Needs the internet route on both phones (Group, Internet route: Help&I's relay, as a new group starts with), with internet on.

1. On phone A, press Help, type "Back door is open" and tap Send, then tap Share where I am and allow location.
2. Turn phone A's internet off and try to send another message.

Pass: phone B shows the message in quotes and an Open their location in Maps link that opens near phone A. In step 2, with both boxes connected, the second message reaches phone B over the group channel, sealed for responders, in pieces of up to 56 bytes if longer. A third board on the same group channel, logging what it hears, never shows the text, and a caller's phone in the same group cannot read it either: only responders hold the key.

## 15. Calls keep going until someone acknowledges

1. Switch phone B's board off. On phone A, press Help.
2. After two minutes, switch phone B's board on. Do not touch phone A.
3. On phone B, acknowledge, then switch phone B's board off again for one minute, then on.

Pass: within ten minutes of step 2, phone B alerts for the call, although its board was off when the button was pressed. Phone A then shows "<name> has seen your call." If phone A did not hear the first acknowledgement in step 3, it still gets it: phone B sends it again when it hears the call repeated. Phone A stops sending once it has heard an acknowledgement (check with a third board's message log, or that phone B gets no more repeats).

## 16. A responder's alert repeats

1. On phone A, press Help. On phone B, dismiss the notification without opening Help&I.

Pass: phone B alerts again about a minute later: once a minute for the first ten minutes, then every ten minutes, for red; every five minutes, then every half hour, for amber. It keeps going with phone B locked and Help&I closed for at least three hours (red). After an acknowledgement, no more alerts arrive, and the ones already showing are cleared. An "I'm OK now" alerts once, quietly, and does not repeat.

Known limit: over the internet route alone, with Help&I closed on phone B, alerts continue only as long as the notifications already scheduled, because the relay cannot wake the phone until push notifications are set up (TODO.md). Over the mesh, each repeat of the call wakes the app and tops them up.

## 17. A responder notices a missed check-in when the caller's phone is off

Needs the internet route (Help&I's relay, as a new group starts with) and internet on.

1. On phone A, turn on a check-in two minutes from now and tap Save. Wait a minute, then switch phone A off.
2. Wait 40 minutes.

Pass: about 35 minutes after the check-in time, phone B alerts "<name> missed a check-in" as a Need a hand call, which stays until someone acknowledges it. With phone A left on and pressing nothing, phone B gets phone A's own missed-check-in call and does not raise a second one.

## 18. Joining a second group

1. On phone B, leave the group, then join a different group that uses the same relay.
2. On a phone in the new group, press Help.

Pass: phone B alerts. (A shared read position used to make it miss the new group's calls.)

## 19. A new responder's acknowledgement counts everywhere

1. With phones A (caller) and B (coordinator) in a group, add phone C as a responder (section 1, steps 2 to 5, on phones B and C). Do not show phone A anything.
2. On phone A, press Help. Acknowledge on phone C.

Pass: phone A shows "Member <n> has seen your call." within a minute. Then remove phone C on phone B, press Help again on phone A, and acknowledge on phone C: phone A must not show it as seen.

## 20. Acknowledging from a responder's watch

Needs phone B paired with an Apple Watch with Help&I on it.

1. On phone A, press Help.
2. On phone B's watch, open Help&I.

3. Press Help on phone A again. With phone B's internet off and its box connected, acknowledge on phone B.
4. Switch phone B off. Press Help on phone A, and acknowledge on phone B's watch. Then switch phone B on, with its internet off and its box connected, and do not touch the watch.
5. With phone B's internet still off, its box connected and its watch beside it on no Wi-Fi of its own, press Help on phone A and acknowledge on phone B's watch.

Pass: the watch lists the caller's name and "Help" with an Acknowledge button. Tapping it acknowledges exactly as on the phone: phone A shows "<name> has seen your call", and the entry leaves the watch. With phone B out of the watch's range, the watch acknowledges over its own internet; with no internet on the watch either, tapping it shows "Not acknowledged: this watch cannot reach the internet. Use your phone." and phone A still shows no acknowledgement. In step 3 the watch stops alerting and the call leaves its list within seconds of the acknowledgement on phone B, and it does not buzz when phone B's acknowledgement makes the call leave phone B's list. In step 4 phone B, once on, stops alerting for the call within a minute and phone A shows the acknowledgement (over the box) as phone B's person's. In step 5 the watch shows "Acknowledged through your phone." with no cross, and phone A shows the acknowledgement.

## 21. A missed check-in noticed with no internet at all

Like section 17, but with the internet off on every phone, so the mesh is the only route.

1. On phone A, turn on a check-in three minutes from now and tap Save. Wait a minute, then switch phone A off.
2. Wait 40 minutes.

Pass: phone B raises "<name> missed a check-in" about 35 minutes after the check-in time. A third board logging the group channel never shows the schedule: it went to phone B's box as a direct message.

## 22. Large text and VoiceOver

1. On phone A, set Settings, Accessibility, Display & Text Size, Larger Text to the largest size, and open Help&I.
2. Turn on VoiceOver and move through the Help tab, then press Help.

Pass: every word on the Help tab can be read without cutting off; Need a hand and I'm OK sit side by side, or one above the other at large text sizes, never cut off. VoiceOver reads each button's name and what it does. After the press it says the status aloud ("Sending…", then "Sent. Waiting for a responder to see it."), and again when a responder acknowledges. Nothing on any screen depends on colour alone: every coloured button and dot also has words.

## 23. A second coordinator

1. On phone B (coordinator), open Group, swipe left on phone C's person, and tap Make coordinator.
2. On phone C, invite a fourth phone, D, as a responder. Then press Help on phone A and acknowledge on phone D.

Pass: phone C shows the coordinator's tools (Invite someone, gaps, Internet route) but no Remove or Make coordinator: only the first coordinator removes people or makes coordinators. Phone A shows phone D's person as having seen the call, although phone B never touched phone D. Phone D's member number is above 1000.

## 24. An acknowledgement that stops counting

1. On phone A, press Help. Acknowledge on phone C (a responder). Phone A shows that C has seen the call.
2. On phone B (the first coordinator), remove phone C.

3. Join phone C again. With phone B's watch (section 20) beside phone B, press Help on phone A and acknowledge on phone C. Then take the watch out of phone B's reach, on its own internet, and on phone B remove phone C again.

Pass: phone A gets a notification "Your call is going out again" saying nobody has seen it now and to call 999 if help is needed now, its status goes back to waiting, and phone B is alerted for the call again. In step 3 phone B's watch alerts for the call again too, and lists it.

## 25. A second coordinator takes in new keys

1. Make phone C a coordinator (section 23). Then on phone B remove a fourth phone, D.
2. On phone C, open Group: under Key update, scan the update code phone B shows for C.

Pass: phone C says "Keys updated." Seven days later (or with the clock moved on), phone C's calls still reach phone A over the local radio.

## 26. A push names the caller

Needs the relay set up with push (TODO.md) and the app signed with the shared keychain group.

1. Lock phone B. On phone A, with the local radio off, press Help.

Pass: phone B's notification reads "<name>: come now", not the relay's generic "A call for help in your group". It never says help is coming.

## 27. An invitation that was never confirmed

1. Make phone C a coordinator. Put phone B (the first coordinator) out of range. On phone C, invite phone D.
2. On phone B, still out of range of C and D, remove phone C. Bring phone B back only near phone A.

Pass: within two days (move the clock on to check sooner), phone D shows a notice that the coordinator who invited it has left and the others may not know it is in the group, asking it to check with another coordinator. With phone B in range of phone D instead, phone D is confirmed within a day and shows no notice.

## 28. Looking for boxes leaves the connected box alone

1. With phone B connected to its box and its internet off, open Box and tap Look for boxes. Choose nothing and leave the Box tab.
2. On phone A, press Help.

Pass: phone B's Box tab still says "Connected", and phone B alerts for the call. Looking stops by itself after about twenty seconds.

## 29. The box reconnects with the phone locked

1. Lock phone B, with Help&I running and its internet off.
2. Switch phone B's box off and on three times in quick succession, then off for two minutes, then on.
3. On phone A, press Help.

Pass: without touching phone B, it alerts for the call over the local radio.

## 30. After the app is ended by the system, and after Bluetooth is switched off

1. With phone B connected, stop Help&I from Xcode (not by swiping it away), then press Help on phone A.
2. On phone B, switch Bluetooth off and on in Control Centre, then press Help on phone A again.

Pass: phone B relaunches, reaches "Connected" and alerts the first time; after Bluetooth comes back it reconnects and alerts the second time.

## 31. The Bluetooth code before pairing, and a wrong code

With a box without a screen:

1. After Help&I has set the box's code (section 2), forget the box in iPhone Settings, Bluetooth. Open Help&I's Box tab before pairing again.
2. Pair, entering a wrong code once, then the right one.

Pass: the Box tab shows the box's code before the pairing prompt appears (and next to the box under Boxes nearby). After the wrong code the Box tab says the box would not talk and to check the code; with the right code it connects without restarting the app.

## 32. A full box during a changeover

1. Fill every channel slot on phone B's box with MeshCore's own app, leaving one slot holding the group's channel.
2. On the first coordinator's phone, remove a phone. Then move the clock on past the seven-day changeover.

Pass: during the changeover phone B's Box tab says there is no free channel; afterwards, without restarting, it reuses the old slot and says "Connected", and calls reach it.

## 33. Typing, text size and taking back a choice

1. On any screen with a text box, including the mobile number box (which has no return key), type something, then tap Done above the keyboard. Type again, then tap an empty part of the Help screen, and on other screens scroll.
2. Under Group, Text size, choose Larger, then Largest. Look at every tab in light and dark mode.
3. Press Need a hand, tap I'm locked out, then tap it again. On phone B, watch the request.
4. Tap Something else.
5. Turn on VoiceOver and go through the Help tab.

Pass: the keyboard always goes away and never hides the tabs for good. Text gets bigger on every tab and nothing is cut off; nothing is grey-on-grey. I'm locked out shows ticked, then unticked, and phone B shows it, then stops showing it. Something else opens the message box with the keyboard, and its microphone takes speech. VoiceOver reads every button, says which choices are selected, and reads the call's status when it changes.

## 34. A responder in two groups, with one box

Needs two coordinators' phones (A and C) with their own groups, and phone B with one box.

1. Phone B joins phone A's group (section 1). Then, under Group, Other groups you respond in, phone B taps Join another group as a responder and joins phone C's group, invited by phone C to respond.
2. Press Help on a caller in phone A's group, then on a caller in phone C's group.
3. On phone B, acknowledge each.
4. Try joining a third group invited to call for help.
5. Switch phone B off, then press Help in each group again, and acknowledge both on phone B's watch.

Pass: phone B's box holds both groups' channels (the Box tab stays Connected) and phone B alerts for both calls, listed under each group's name. Each acknowledgement shows only on its own group's caller. A call in one group never appears on the other group's phones. In step 4 phone B says it can only respond in a further group. In step 5 phone B's watch alerts for both calls and each acknowledgement shows only on its own group's caller.

## 35. Sounds, spoken words and touch for a caller

Needs phone A (a caller) and phone B (a responder), with phone A's watch, and the ringer on phone A switched to silent.

1. On phone A, with the internet off and no box, press Help.
2. Turn the internet back on and press Help again. Leave it a few seconds, then acknowledge on phone B.
3. Press Need a hand on phone A.
4. Under Group, Your settings, turn Sounds and spoken words off, and repeat step 2.
5. Turn VoiceOver on and repeat step 2.
6. Repeat steps 1 to 3 on phone A's watch, with its phone switched off.

Pass: every press is felt as a short tap. In step 1 phone A plays a soft "eeh-ooh", high then low, then says "Your Help message has not been sent. Try again, or call 999." In step 2 it says "Your Help message has been sent." with no sound, and then, only once phone B has acknowledged, plays the chime and says "<name> has seen your Help message, and says: I'm dealing with it." In step 3 phone A shows and says "You have requested non-urgent assistance. If you need help sooner, please press Help." (or the words in their profile). All of this is heard with the ringer on silent. In step 4 nothing is heard, but the taps and the words on the screen remain. In step 5 VoiceOver reads each message once, and it is not spoken a second time. In step 6 the watch does the same, with its own vibrations. A watch not yet set up shows how to set it up instead of the buttons.

## 36. Profiles

Needs phone A (a caller), phone B (a responder) and phone C (the coordinator), all with the internet.

1. On phone C, under Group, Profiles, add a profile called Living alone. Give it to phone A's person. Set its Help words to SOS, its buttons to a symbol only, and turn off They may change this under Sounds. Save.
2. On phone A, look at the Help screen, then Group, Your settings, and try to turn Sounds and spoken words off.
3. On phone C, set the buttons back to words and a symbol, turn on Show them only the three buttons, and save.
4. On phone C, delete the profile.

Pass: in step 1 phone C warns that SOS can sound like an emergency service. In step 2 phone A's buttons show only their symbols (VoiceOver still reads the words), the sounds show as words with "Set by your coordinator." instead of switches, and the screen offers to ask the coordinator to change one. In step 3 phone A shows only the Help screen, with the 999 notice, and phone C suggests making a second coordinator. In step 4 phone A is back on the first profile, with all its screens.

5. Give phone A the profile again, with its sounds locked. On phone A, under Group, Your settings, tap Ask the coordinator to change one, choose The sounds, write "Too loud at night" and send it. Look at phone A's Help screen.
6. On phone C, under Group, For coordinators, read the request and tap Done.

Pass: in step 5 phone A says the request was sent, and nothing about it appears on the Help screen. In step 6 phone C shows "<name> asks to change the sounds: Too loud at night", and it goes when Done is tapped. With the internet route not set up, phone A says it was not sent and why.

## 37. Closing a call, and I'm OK after a call

Needs phone A (a caller), phone B (a responder) and phone C (the coordinator), with the internet.

1. On phone A press Help, then I'm OK.
2. On phone B, look at the call, wait for its next alert, then acknowledge it.
3. On phone C, under Profiles, set Calm reminders every 5 minutes and How many to 2, then repeat steps 1 and 2 without acknowledging for 15 minutes. Then set I'm OK to Trust it: the call closes, and turn on They may close their own call. On phone A press Need a hand, then I'm OK.
4. On phone A press Help, then Close this call.
5. On phone A press Help. On phone C, on the Respond screen, tap Close this call, write a reason, and close it.
6. Repeat step 5 with the internet off on every phone, using the boxes.

Pass: in step 1 phone A says it has been sent, then "Your responders have been told you're OK. One of them will still check on you." Phone B shows "Says they're OK now. Please still check on them.", and its alerts come calmly, about every half hour, not urgently, until it acknowledges. In step 3 phone B gets two calm reminders, five minutes apart, then no more while the call stays open; then the Need a hand call is closed on every phone and phone B's alerts stop. In step 4 phone A says "You closed your Help call." In step 5 phone A and phone B show who closed it and the reason. In step 6 they show who closed it, without the reason. Nothing closes or times out a call on its own.

## 38. Choosing the caller's sounds

Needs phone A (a caller) and phone C (the coordinator). Ringer on phone A switched to silent.

1. On phone C, under Group, Profiles, open phone A's profile. Tap Hear the not-sent sound, and Hear the seen sound, for each choice of each.
2. Choose A buzzer for the not-sent sound, save, and on phone A, with the internet off and no box, press Help.
3. Choose No sound for both, save, and repeat step 2, then press Help with the internet on and acknowledge it on another phone.
4. On phone A, under Group, Your settings, tap each Hear button.

Pass: in step 1 each choice is heard as named: a soft eeh-ooh, high then low; a buzzer; a chime; nothing for No sound. In step 2 phone A plays the buzzer, then says the words. In step 3 no sound is played, but the words are still spoken and the taps still felt. In step 4 phone A plays its own profile's sounds, with the ringer on silent.

## 39. The log

Needs phone A (a caller), phone B (a responder), and phones C and D (two coordinators), with the internet.

1. On phone A press Help; on phone B acknowledge it; on phone C close it with a reason.
2. On phone C, under Group, Log, read the entries, then tap Export the log and save it to Files.
3. On phone D, under Profiles, change a profile's name. Then on phone C, under Log, switch Keep a log for this group off, and press Help again on phone A.

Pass: in step 2 the log lists the call heard, phone B's acknowledgement and phone C's close with its reason, each with the time, newest first, and the exported file has the same lines. In step 3 phone C shows under For coordinators that phone D changed the profile, and the log records it and the log being switched off, but nothing after.

## 40. The Help complication and its countdown

Needs a real Apple Watch with Help&I set up (section 7), and a responder's phone. The simulator cannot show the countdown running with the wrist lowered.

1. On the watch, edit a face and add Help&I's Help complication in each place it offers: a circle, a corner, a wide slot and the line of text. Try a face of each kind you have.
2. Tap the complication, and do nothing for the whole minute, with the wrist lowered after the first ten seconds.
3. Tap it again, and press I'm OK after a few seconds.
4. Tap it again, and press Help after a few seconds.
5. On the watch of someone who responds but does not call, tap the complication.

Pass: in step 1 the complication shows a raised hand and Help wherever it fits. In step 2 the watch opens Help&I with the red button counting down from 60, taps the wrist every 10 seconds, at 30 seconds left says "Calling for help in 30 seconds. Press I'm OK to stop, or Help to ask for help now." (in the profile's own words), and at 0 sends Help, which the responder receives; it keeps counting with the wrist lowered. In step 3 the countdown stops, the watch shows and says "Stopped. Nothing has been sent." and nothing is sent; with VoiceOver on, it reads I'm OK during the countdown as "I'm OK. Press to stop the countdown: nothing is sent." In step 4 Help goes at once. In step 5 nothing counts down: the watch shows the cross and says at once that they are not a caller in this group, to use their phone or call 999.

## 41. Home Wi-Fi with nothing else

Needs phone A (a caller) and phone B (a responder) on the same home Wi-Fi network, with no box connected and the internet route not set up (or the broadband unplugged, Wi-Fi still on).

1. Open Help&I on both phones. Allow it to find devices on the local network when asked. Look under Group, Home Wi-Fi on each.
2. On phone A press Help; on phone B acknowledge it.
3. On phone A press Need a hand, type a note, and share where you are.
4. Lock phone B, wait a minute, and press Help on phone A.
5. Join phone C, of another group, to the same Wi-Fi, and press Help on phone A.
6. Switch phone B off, then press Help on phone A. Switch phone B on, open Help&I, and wait a minute.
7. Turn Local Network off for Help&I on phone A in Settings, open Help&I, then turn it back on.

Pass: in step 1 each phone shows one other phone of the group on this Wi-Fi. In step 2 phone A shows Home Wi-Fi: sent, then the acknowledgement, and phone B alerts. In step 3 phone B shows the note and the position. In step 4, without section 42's set-up, phone A shows the cross for Home Wi-Fi, never a false "sent". In step 5 phone C shows nothing, and phone A still counts only phone B. In step 6 phone A shows the cross for Home Wi-Fi within about 30 seconds of phone B going off, and Group, Home Wi-Fi counts phone B again soon after it is back, without restarting either app. In step 7 the Group screen says Local Network is off, and the message goes once phone B is counted again.

## 42. Home Wi-Fi with the phone locked

Needs a signed build (shared keychain group and the Network Extensions capability, TODO.md), and phones A (a caller) and B (a responder) on the same home Wi-Fi, with no box and no internet route.

1. On phone B, under Group, Home Wi-Fi, enter the Wi-Fi's name and tap Keep listening on this Wi-Fi. Then reopen Group, once with phone B on that Wi-Fi and once off it.
2. Close Help&I on phone B (swipe it away) and lock it. Press Help on phone A.
3. Tap phone B's alert and acknowledge.
4. Take phone B off the Wi-Fi (another network or mobile data only) and press Help on phone A again.
5. On phone A, also set up Keep listening on this Wi-Fi, close every other phone's Help&I, and press Help on phone A.
6. With phone B listening locked, press Help on phone A, then I'm OK; then press Help again and acknowledge it on phone C.

Pass: in step 1 Group says "Listening on" the Wi-Fi only while phone B is on it, and "Set to listen" otherwise. In step 2 phone B alerts within a few seconds, naming the caller, even with the app closed and the phone locked. In step 3 phone A shows the acknowledgement. In step 4 phone B does not alert over Wi-Fi, and phone A shows the cross for Home Wi-Fi (other routes as set up). In step 5 phone A shows the cross for Home Wi-Fi: its own listener never counts as another phone. In step 6 phone B alerts for the call, and again with its resends (at most once a minute) until someone acknowledges; after I'm OK its alert becomes a calm "says they're OK now", and after phone C's acknowledgement phone B's alert goes.

## 43. A phone restarted and not yet unlocked

Needs a signed build with push (TODO.md), and phones A (a caller) and B (a responder) in one group.

1. Restart phone B and do not unlock it. Press Help on phone A.
2. Unlock phone B and open Help&I.

Pass: in step 2 phone B shows its group as before, never the welcome screen, and the call from step 1 arrives within a minute of unlocking. Its saved calls and settings are all still there.

## 44. Many calls at once, and Help&I's warnings

Needs phones A and B as callers and phone C a responder in two groups (one as its call group, one as another).

1. Press Help on phone A and Need a hand on phone B, close Help&I on phone C and lock it, and acknowledge nothing for 15 minutes.
2. On phone C, in Settings, Notifications, Help&I, turn notifications off, open Help&I; turn them on again and turn Time Sensitive off, and open Help&I again.
3. Turn the box near phone C off at the wall while it is connected, and back on.
4. Delete the app's Bluetooth pairing on the box side (reset the box), then watch Group, Box on phone C.

Pass: in step 1 phone C keeps alerting for both calls through the 15 minutes, neither falling silent. In step 2 a banner says notifications are off, then that Time Sensitive is off, each with Open Settings, and goes once put right. In step 3 phone C reconnects without help. In step 4 it says the box did not answer, or was reset, and keeps trying rather than show Connecting for ever.

## 45. A relay pass

Needs a relay of your own deployed with `REQUIRE_PASS` set to `1` and `ISSUER_KEY` set to the issuer's public key (`relay/README.md`, Passes), phones A (the first coordinator) and B (a responder) on it with the internet route set up and internet on, and the issuer key file on your Mac.

1. On phone A, open Group, Internet route and read the group ID. On the Mac, `cd relay && node pass.mjs issue <group ID> 1`.
2. Before pasting it, press Help on phone B's caller (or any member's phone) and read the internet route's reason on the call screen; close the call.
3. On phone A, paste the pass under Paste the pass here and press Save pass. Press Help on phone B again, and acknowledge it from phone A.
4. On phone B, open Group, Internet route.
5. The next day, press Help on phone B again.

Pass: in step 2 the internet route says the relay needs a pass for this group and that a coordinator can add one under Group, Internet route, and Group, Internet route on phone A says the same; the mesh route is unaffected. In step 3 the pass is saved ("Saved. Members get the pass at once..."), the call goes over the internet route and the acknowledgement comes back. In step 4 phone B shows the pass is good until tomorrow's date and the time it was issued, having had it from phone A without scanning anything. In step 5 the internet route says the group's relay pass has run out, and Internet route on both phones says when. Nothing ever says help is coming.


## Help&I firmware on the box

Sections 46 to 58 need boxes running Help&I's own firmware (`firmware/build.sh`, environment `heltec_v4_helpandi` on a Heltec WiFi LoRa 32 V4 with the buttons, buzzer and mains divider of `firmware/DESIGN.md` section 5, or `heltec_v4_helpandi_dev` for a plain board). Nothing in them has been run: the firmware has only been compiled. Provision with the app (section 60), or with a test tool that sends DESIGN.md section 6's bytes over the companion link, and say which in the run. "Box A" is a Help&I box in the group as its own member; phone B is a responder with its own stock box. Keep phone A off unless a step says otherwise.

## 46. The box's buttons with no phone

1. On box A, press red once, briefly.
2. Hold red down for ten seconds.
3. On phone B, acknowledge.

Pass: box A beeps once and shows "Sending...", then "Sent. Waiting for someone to see it.", and never anything that suggests help is on its way. Phone B alerts within a few seconds. Holding red makes no second call (phone B's list shows one). Only after step 3 does box A show "A responder has seen your call.", with its seen sound, and the LED goes out.

## 47. The cross on the box

1. Take box A's antenna off, or set box A to a frequency outside the UK bands, and press amber.

Pass: box A shows a cross and "Not sent. Nobody may know you need help. If you need help now, call 999.", with its not-sent sound, and the LED blinks. With the frequency outside the bands it sends nothing at all (check with a third board), and MeshCore's own transmit power setting is pulled down to the band's cap within a second of being raised.

## 48. Resends from the box until someone acknowledges

1. Switch phone B's box off. On box A, press red.
2. After two minutes, switch phone B's box on. Do not touch box A.
3. On phone B, acknowledge.

Pass: phone B alerts within ten minutes of step 2. Box A shows "seen" only after step 3, and a third board's log shows box A's repeats (at 30 seconds, 1, 2 and 4 minutes, then every 10) stopping after it.

## 49. A second press, and I'm OK on the box

Run once with the box's profile set to "I'm OK closes the call" (A) and once to "stops the urgent repeats" (B), re-provisioning in between.

1. On box A, press red, wait five seconds, then press red again.
2. Wait five seconds, then press green.

Pass: phone B shows two calls from the box's unit. After step 2 it shows I'm OK for both, quietly. In A both show as closed by the caller and box A says "Your call is closed."; in B they stay open until a responder acknowledges, box A's repeats carry the I'm OK, and box A still says it is waiting for someone.

## 50. Bouncing, stuck and start-up presses

1. Tap red as lightly and quickly as you can, ten times.
2. Hold red while plugging box A in, keep holding for ten seconds, then let go.
3. Press red once.
4. Wait five seconds, then press red, amber and green together with the flat of a hand.
5. Wait five seconds. Press red, let go, and press green within two seconds.

Pass: in step 1 each tap that beeps makes exactly one call and none makes two. Step 2 makes no call. Step 3 makes one. Step 4 makes a Help and a Need a hand and no I'm OK. Step 5 makes one Help and no I'm OK.

## 51. The countdown on a plain Heltec (development layout)

Needs a board flashed with `heltec_v4_helpandi_dev`.

1. Press PRG briefly, and do nothing for a minute.
2. Press PRG briefly, then press it again after a few seconds.
3. Hold PRG for three seconds.

Pass: step 1 counts down from 60 on the screen, beeping every 10 seconds, beeps twice at 30 seconds left, and sends Help at 0. Step 2 stops the countdown, with a short tone, and sends nothing. Step 3 sends I'm OK.

## 52. Sounds, screen and LED for someone with poor sight or hearing

Pass: the press, "seen" and the cross each have a sound that can be told apart from the others across a room, and none is harsh. The screen's words can be read at arm's length, and the screen stays on while a call is open, going dark two minutes after the last press otherwise (a power cut shows on its bottom line while it is on, and on battery the box then sleeps: section 58). The LED is on while a call waits, blinks when nothing was sent, and is off once a responder has seen it; it can be seen in a dark room.

## 53. A power cut

1. With box A on its mains adapter and battery, and the person's power-cut report turned on at provisioning, switch the adapter off at the wall for one second, then on.
2. Switch it off and leave it off.
3. On phone B, acknowledge the power cut.

Pass: step 1 reports nothing. In step 2 box A shows "Power cut" on its bottom line within ten seconds (with the hours once estimated); phone B hears a request from the box's unit marked Power cut within a minute, then battery notes ("About 24 hours of battery left.", and so on) as the estimate passes each mark; red still works throughout. After step 3 only the final battery warning still comes. When the adapter goes back on, phone B gets "Power is back." With the report turned off, box A still shows the power cut but sends nothing.

Without the mains wire (a box built with `HI_MAINS_SENSED=0`, or the development build):

4. Charge box A fully on its adapter and leave it on for an hour. Log the battery millivolts once a minute throughout steps 4 to 7 (the info reply, 0x70, over the companion link, or MeshCore's serial console).
5. Switch the adapter off at the wall for one second, then on. Leave it on for an hour.
6. Switch the adapter off and leave it off for four hours.
7. Switch it on again.

Pass: steps 4 and 5 report nothing and show no power cut (a full cell held by its charger never fires). In step 6 box A shows "Power cut?" (with the hours once estimated) within half an hour, and phone B hears the request with the note "Power probably cut: the battery is falling."; the info reply's mains byte has bit 2 set. In step 7 phone B gets "Power probably back." within an hour and a half (the box, asleep, reads the cell every ten minutes). From the log, write down the step the charger makes when it finishes (the reading on mains, before and after it stops charging) and how much a full cell falls in its first half hour on battery: `MainsEstimate::kFallMV` in `firmware/core/power.hpp` must stay above the first and `kFlatMV` below the second. Repeat step 6 from a half-charged cell (unplug at about 3.9 V while charging): the power cut shows within about ten minutes.

## 54. Battery life on battery alone

1. Charge box A fully, unplug it, and leave it idle, pressing red once an hour and having phone B acknowledge each press within a minute.
2. With a meter in the battery lead, read the draw while a call is open (awake) and once the box has gone quiet (asleep), and time how long it stays awake after one of its ten-minute wakes.

Pass: it runs at least 24 hours, every press is heard, each press wakes the box at once, and its hours-left estimates are within an hour of the truth near the end. Record the measured draws: they replace `HI_DRAW_AWAKE_MA` and `HI_DRAW_ASLEEP_UA` in `firmware/box/platformio.local.ini`, and the awake time per wake replaces `kAwakePerWakeMs` in `firmware/core/box.hpp` if it is far from three seconds.

## 55. Transmit power and duty cycle

Needs an RF power meter or a calibrated spectrum analyser.

1. Measure box A's output at each band with its antenna type set at provisioning.
2. Press red, amber and green repeatedly for an hour.

Pass: output is within the band's ERP limit with the antenna's gain. In step 2 the box's own sending stays under the band's duty cycle, and red still goes out after amber and green have used their share. Record the measured amplifier gain: it replaces `HI_AMPLIFIER_GAIN_DB`.

## 56. The box and its phone together

1. With phone A connected to box A and the internet on, press red on the box.

Pass: phone A is told of the call (push 0xA3) and carries it on its own routes; phone B hears the call once, whether by the mesh or the internet, and box A shows "seen" after B acknowledges, by either route.

## 57. Provisioning over Bluetooth

1. With box A unprovisioned, press red.
2. Send the group (0x71) and members (0x72) over the companion link, then query 0x70.
3. Press red. Remove the responder from the group on the coordinator's phone, and wait for the repeat of the signed removal.
4. Send the responder's first name (0x76, one name, member number and "Pat"), power-cycle the box, press red and acknowledge on phone B.
5. Send 0x76 with a total of 0, press red and acknowledge again.
6. Power box A off, disconnect its screen so that it shows nothing at start, and power it on. Forget the box in the phone's Bluetooth settings, then pair from the Help&I app, first with 123456, then with the code the screen showed in step 2, then with the label code from step 2's info reply, and watch the state LED. Query 0x70, press red and acknowledge on phone B.
7. Power box A off, reconnect its screen and power it on twice, pairing from the Help&I app each time.
8. Send forget (0x75) and press red.
9. Power box A off, disconnect its screen and power it on. For two minutes, look for it from a phone's Bluetooth settings, from the Help&I app and from a Bluetooth scanner app, and watch the state LED. Wait until the LED has been dark for a minute, then press red. Reconnect the screen.

Pass: step 1 shows "Not set up yet. Add this box to a group in the Help&I app." with the not-sent sound. Step 2 answers each command with OK and the info reply shows the unit, member and next request number and a six-digit label code that is not 123456 and not the code on the screen; the box survives a power cycle still provisioned, with the same label code. In step 3 the call goes, and after the removal the responder's acknowledgement no longer counts (the box goes back to waiting). In step 4 the info reply counts one name and the box says "Pat has seen your call." in letters the screen can show, with nothing but the unit number heard on air (check with a third board); in step 5 it is back to "A responder has seen your call.". In step 6 the app pairs with the label code only, not with 123456 or the screen's code; the LED gives no flashes; the info reply shows the same label code; the red press goes out (heard on phone B) with the press sound, the LED stays lit while it waits and the seen sound plays at the acknowledgement. In step 7 the screen shows "code" and a six-digit number that is not 123456 and not the label code and differs between the two starts, the app pairs with that code and the box still holds its group and its label code (query 0x70). Step 8 is back to step 1, with the info reply counting no names and showing a label code of 0. In step 9 no phone or scanner finds the box and nothing can connect to it; the LED gives two short flashes every two seconds for the two minutes after it starts, then goes dark; the red press gives the not-sent sound and the two short flashes come back for two minutes.

## 58. Sleeping and waking on battery

Needs box A on battery with its mains adapter off (on a plain board, ground GPIO 4 to stage a power cut: the development layout pulls that pin up) and a third board logging the channel.

1. Press red, have phone B acknowledge, and leave the box for three minutes.
2. Tap red, letting go at once.
3. Have phone B acknowledge, wait three minutes, then plug the adapter in (or unground GPIO 4).
4. Unplug it again, wait three minutes, connect phone A over Bluetooth, then disconnect it and wait three minutes.
5. Press the board's reset button, then press red, amber and green as in section 55 for half an hour, press reset again, and keep pressing for the rest of the hour.
6. With no phone connected, leave the box asleep on battery for an hour (six wakes to read the battery), then press red and have phone B acknowledge.

Pass: after step 1 the screen is dark, the LED is off, the box is no longer visible over Bluetooth and the third board hears nothing more from it. Step 2 sends Help within two seconds of the tap, with the press sound, and the screen comes on: the press that woke the box counts. After step 3 "Power is back." reaches phone B and the box stays awake (visible over Bluetooth). In step 4 the box is visible again within a minute of the adapter going off (it wakes every ten minutes to read the battery, for a few seconds), the phone connects and keeps it awake, and after the disconnect it sleeps again. In step 5 the screen still shows the last call as seen, phone B hears no new power-cut report, and the third board's log shows the box's own sending stay under the band's duty cycle across the reset, as if there had been none. In step 6 the call carries the true time to within a minute (phone B's log of the call, or the third board's log of its frame), not the time the box last heard a contact, and the box still keeps under the band's duty cycle: its record of the hour came through the wakes.

## 59. A release box

Needs a Heltec V4 nobody needs afterwards: the eFuses are one-way. Keys as in `firmware/DESIGN.md` section 16, in a directory outside any repository.

1. `firmware/build.sh --release` with `HI_RELEASE_KEYS` set, then the flash, key and eFuse commands it prints, in that order.
2. Power-cycle the board. Provision it (section 57, steps 2 and 3) and press red.
3. `espefuse.py --chip esp32s3 --port PORT summary`, then `esptool.py --chip esp32s3 --port PORT read_flash 0x10000 0x1000 out.bin`.
4. Write the plain `.pio/build/heltec_v4_helpandi/firmware.bin` to 0x10000 with `esptool.py write_flash` and power-cycle.
5. Write `release/firmware.bin` back to 0x10000 and power-cycle.

Pass: step 2 boots to the pairing code, provisions and sends the call like any box. In step 3 the summary shows SECURE_BOOT_EN, SPI_BOOT_CRYPT_CNT 7 and the two keys, and the read is refused. Step 4 does not boot (a plain image on an encrypted box); step 5 boots again. Say in the run which esptool version was used.

## 60. Adding a Help&I box with the app

Needs box A unprovisioned, phone A in the group as a caller (not a coordinator), phone B as the group's first coordinator who also responds, and a third board logging the channel. Internet on for both phones.

1. On phone A, pair with box A in the Box tab.
2. On phone B, pair with box A instead of its own box. In the Box tab, give it a name, try to add it before choosing anyone, then choose phone A's person under In the home of, and tap Add this box to the group. Once box A shows it is set up, with phone B still paired with it, press red on it, wait for phone B's turn and acknowledge on phone B.
3. On phone B, open the box's member page, turn on Tell responders about a power cut at their home, and pair phone B with its own box again.
4. On phone A, pair with box A again and open the Box tab. Press red on box A with phone A's Bluetooth on, then with it off.
5. On phone B, acknowledge each call. Then, in Advanced settings, turn on Responders' first names on boxes, press red on box A and acknowledge on phone B. Turn it off again, and press and acknowledge once more.
6. On phone B, set box A's antenna to an external antenna in its member page, and raise its gain to 8 dBi, then to 14 dBi, then to 27 dBi. At 27 dBi, look at box A's screen, press red on box A, and send Help from phone A's app while it is paired with box A. Set it back to the standard whip.
7. Pair phone A with a box on MeshCore's stock firmware.
8. Pair phone A with box A again. With phone A's Bluetooth off, press red on box A, then turn its Bluetooth on again with the app open. Acknowledge on phone B.
9. On phone B, remove box A from the group, with phone A paired with box A.
10. Add box A to the group again as in step 2, in phone A's person's home, and pair phone A with it again. Have phone A join a second group as a responder (start one on a spare phone), then, on phone A, leave the group so that the second becomes its call group.
11. Add box A to the group again as in step 2 and pair phone A with it. Set phone A's clock an hour ahead (Settings, General, Date & Time, automatic off), pair it with box A again so that it sets the box's clock, set phone A's clock back to automatic, and press red on box A. Leave box A for an hour before using it in another section: its clock stays an hour ahead until then.

Pass: in step 1 the Box tab says Firmware: Help&I box and asks phone A's person to ask their coordinator, and box A still shows "Not set up yet". In step 2 Add this box to the group cannot be tapped until someone is chosen under In the home of, and once the box is added In the home of offers no "Choose someone" and lists people only, never a box; the box appears in the member list on both phones as a caller with its own unit, and box A shows it is set up within a minute; phone B alerts for the red press from its turn, as for anyone's call, and box A shows "seen" after the acknowledgement. In step 4 the Box tab shows the box's name, unit, Set up, On mains and the call with its status as the box shows it; phone A shows no alert for the box's call, nor does phone A's watch if it has one (section 7), and phone B hears it once (by both the radio and the internet when phone A's Bluetooth is on, by the radio only when off). With Bluetooth on, box A shows "seen" after phone B acknowledges even when phone B's acknowledgement goes only by the internet (phone B's box off). In step 5 box A says "Sam has seen your call." (phone B's person's first name) with names on, and "A responder has seen your call." again once they are off; the third board hears no name on air. In step 6 the member page shows up to 9 dBm at 869.4–869.65 MHz and up to -4 dBm at 868.0–868.6 MHz for 8 dBi, up to 3 dBm and "must not send" for 14 dBi, and "must not send" in both with the words that the box must not send at all for 27 dBi; each time the box's power cap in its info (0xA0) is the app's figure for the band box A is on, without pairing again, and at 27 dBi box A's screen says "This box cannot send: its antenna is not allowed. Ask your coordinator.", pressing red shows the cross with "Not sent: this box's antenna is not allowed. If you need help now, call 999.", and neither that press nor phone A's Help puts anything from box A on the channel the third board logs (phone A's Help still goes by its other routes). In step 7 the Box tab says Firmware: MeshCore box and nothing else changes. In step 8 the call reaches phone B over the internet within a minute of phone A's Bluetooth coming back (the relay's log, or phone B with its own box off), and phone A shows no alert. In step 9 box A shows "Not set up yet" within a minute and phone A's Box tab says the box is not in the group; pressing red on box A puts nothing on the channel the third board logs. In step 10 box A shows "Not set up yet" within a minute of phone A leaving the group. In step 11 phone B alerts for box A's call at once, as the first responder, not an hour later.

## 61. A power cut, as the phones show it

1. Section 53, steps 1 to 3 (or, without the mains wire, step 6), with box A added as in section 60 and its power-cut report on, and phone A connected to it.
2. Repeat with box A's report off on its member page.
3. Pair phone A with a stock MeshCore box on its mains adapter, keep the app open on the Help tab for an hour, then switch the adapter off and keep the app open for another hour.

Pass: in step 1 phone B shows a calm notification, "<box name>: power cut at home" ("probably a power cut" without the wire), not a call for help, and the Respond tab shows "Power cut at their home. Their box is on its battery." with the battery notes, until someone acknowledges; phone A shows no alert, and its Box tab shows the power cut and the hours left. In step 2 nothing reaches phone B. In step 3 nothing shows for the first hour; within about half an hour of the adapter going off, the Help tab says the box is running on its battery and offers Tell my responders, and tapping it sends a Need a hand that phone B sees with the note "Power probably cut: the battery is falling.". The offer never shows with box A, which reports for itself.
## 62. A coordinator takes over from a lost phone

Needs phone B as the first coordinator, phones C and D as coordinators (section 23) and phone A as a
caller, all with boxes and the internet route.

1. On phone B, open Group, If your phone is lost, and choose phone C's person. On phone A, open
   Group.
2. Turn phone B and its box off. On phone C, open Group, If B's phone is lost, and tap Take over from B,
   then Take over now to confirm. Show phone A and phone D their update codes under New keys to
   hand out, and scan them.
3. Press Help on phone A and acknowledge on phone D. Then turn phone B and its box on again, and
   on phone B try to acknowledge the call and to remove phone D.
4. Start again with no deputy. With phone B off, on phone D open If B's phone is lost and tap Agree
   that C may take over; then take over on phone C.
5. Start again with no deputy and phone B off, and on phone C open If B's phone is lost (with the
   clock moved on six days, then eight). At eight, tap Take over.
6. Repeat step 5 in a group with no relay (Group, Internet route, none).
7. Start again with phone D named deputy and phone B off. On phone D tap Agree that C may take
   over. Turn phone C's box off and put phone C in flight mode; take over on phone D, then on phone
   C; then turn phone C's box on and flight mode off.

Pass: in step 1 phone A lists C's person as "deputy to the first coordinator" and B's as "first
coordinator". In step 2 phone C's screen says when phone B was last heard from and that it can take
over now as deputy; afterwards every phone lists C's person as first coordinator and phone B's
person is gone, and each phone's Log says who took over, from whom and how. In step 3 phone A shows
phone D's person as having seen the call; phone B's acknowledgement and removal change nothing on
phone A or D, and the relay refuses phone B. In step 4 phone C's screen says D agreed, and the
takeover goes through at once. In step 5 phone C cannot take over at six days (the screen says
from when it can); at eight it offers Take over, says "Checking with the relay." and then, as the
relay's own clock has not moved and it heard from phone B within the week, "<B's name>'s phone has
been in touch in the last week, so it cannot be taken over yet.", and nothing changes on any phone.
In step 6 phone C offers no Take over at eight days and says another coordinator must agree. In
step 7, within a few minutes every phone, phone C's included, lists D's person as first coordinator;
phone C says under New code from your coordinator that D's person also took over and the group
follows them rather than C's person, and takes the update code phone D shows it. No screen says or
suggests that help is coming.
