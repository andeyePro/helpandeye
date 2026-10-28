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

Pass: phone A shows a cross and "Not sent. Nobody has been told.", lists why each route failed, offers Try again, and says "If you need help now, call 999." With a SIM in phone A and a mobile number saved by at least one responder (Group, Your mobile number), it also offers Send as a text, which opens a ready-written message naming no one, addressed to every responder with a number. With no responder number saved, Send as a text is not offered at all.

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
6. On phone A, leave the group.

Pass: in step 3 the watch says calls go over its own internet, phone B alerts, and the watch shows the acknowledgement only after phone B's person pressed it. In step 4 phone B shows one call, not two. In step 5 phone B's watch buzzes for the call (it does not buzz while phone B is on and alerting), and phone A shows the acknowledgement as phone B's. After step 6 phone A's watch no longer calls or alerts for the group. With no internet on the watch and its phone out of reach, the watch shows a cross and tells the wearer to use their phone or call 999.

## 8. Removing a lost phone

Needs phone C from section 6.

1. On phone B (the coordinator), open Group, swipe left on phone C's person, and tap Remove.
2. On phone B, under New keys to hand out, show phone A its update code, and scan it on phone A under Key update.
3. On phone A, press Help.

Pass: phone B alerts, phone C does not. Phone A's person still has the same unit number.

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

Pass: the cross and "Not sent. Nobody has been told." appear at once, not "Sending…".

## 13. Check-ins

1. On phone A, open Group, turn on Check in at set times, set the first check-in to two minutes from now with no second one, and tap Save.
2. Wait for the reminder notification and do nothing for 32 minutes.

Pass: the reminder arrives at the set time. About 30 minutes later (within a minute of that, with Help&I open) phone B gets a Need a hand call showing "Missed a check-in". Repeat, pressing I'm OK now when the reminder comes: phone B gets the green call and no missed check-in.

## 14. Typed messages and location

Needs the relay set up (Group, Internet route) on both phones, with internet on.

1. On phone A, press Help, type "Back door is open" and tap Send, then tap Share where I am and allow location.
2. Turn phone A's internet off and try to send another message.

Pass: phone B shows the message in quotes and an Open their location in Maps link that opens near phone A. In step 2, with both boxes connected, the second message reaches phone B as a direct message between the boxes, cut to 96 bytes if longer. A third board on the same group channel, logging what it hears, never shows the text: it is encrypted to phone B's box alone.

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

Needs the relay set up and internet on.

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

Pass: the watch lists the caller's name and "Help" with an Acknowledge button. Tapping it acknowledges exactly as on the phone: phone A shows "<name> has seen your call", and the entry leaves the watch. With phone B out of the watch's range, tapping it shows "Not acknowledged" and nothing is sent.

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

Pass: phone A gets a notification "Your call is going out again" saying nobody has seen it now and to call 999 if help is needed now, its status goes back to waiting, and phone B is alerted for the call again.

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

Pass: in step 1 the complication shows a raised hand and Help wherever it fits. In step 2 the watch opens Help&I with the red button counting down from 60, taps the wrist every 10 seconds, at 30 seconds left says "Calling for help in 30 seconds. Press I'm OK to stop, or Help to ask for help now." (in the profile's own words), and at 0 sends Help, which the responder receives; it keeps counting with the wrist lowered. In step 3 the countdown stops and nothing is sent. In step 4 Help goes at once.

## 41. Home Wi-Fi with nothing else

Needs phone A (a caller) and phone B (a responder) on the same home Wi-Fi network, with no box connected and the internet route not set up (or the broadband unplugged, Wi-Fi still on).

1. Open Help&I on both phones. Allow it to find devices on the local network when asked. Look under Group, Home Wi-Fi on each.
2. On phone A press Help; on phone B acknowledge it.
3. On phone A press Need a hand, type a note, and share where you are.
4. Lock phone B, wait a minute, and press Help on phone A.
5. Join phone C, of another group, to the same Wi-Fi, and press Help on phone A.

Pass: in step 1 each phone shows one other phone of the group on this Wi-Fi. In step 2 phone A shows Home Wi-Fi: sent, then the acknowledgement, and phone B alerts. In step 3 phone B shows the note and the position. In step 4, without section 42's set-up, phone A shows the cross for Home Wi-Fi, never a false "sent". In step 5 phone C shows nothing.

## 42. Home Wi-Fi with the phone locked

Needs a signed build (shared keychain group and the Network Extensions capability, TODO.md), and phones A (a caller) and B (a responder) on the same home Wi-Fi, with no box and no internet route.

1. On phone B, under Group, Home Wi-Fi, enter the Wi-Fi's name and tap Keep listening on this Wi-Fi.
2. Close Help&I on phone B (swipe it away) and lock it. Press Help on phone A.
3. Tap phone B's alert and acknowledge.
4. Take phone B off the Wi-Fi (another network or mobile data only) and press Help on phone A again.

Pass: in step 2 phone B alerts within a few seconds, naming the caller, even with the app closed and the phone locked. In step 3 phone A shows the acknowledgement. In step 4 phone B does not alert over Wi-Fi, and phone A shows the cross for Home Wi-Fi (other routes as set up).
