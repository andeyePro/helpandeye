# App specification

Draft for the first Help&I phone and watch app. Decisions already taken are in
[design-decisions.md](design-decisions.md); this file says how the app carries them out, and
lists what is still open. Items marked **Proposed** are not yet agreed.

## Scope of the first release

- iOS phone app and watchOS app. Android follows.
- One app with two roles: a person can be a caller, a responder, or both.
- Routes: internet (mobile data or Wi-Fi), SMS, and the MeshCore mesh through a Heltec board on
  MeshCore's standard companion firmware, over Bluetooth.

## Groups and roles

- A **coordinator** sets up a group and invites its responders and callers. Joining is by
  invitation only, and each person accepts a consent screen saying what is sent and who sees it.
- **Responders** enter their availability. The coordinator is told when the rota has a gap.
- **Peer-to-peer groups** are allowed: every member is both caller and responder, as on a street
  or a works team.
- A group can have more than one coordinator, so that it does not depend on one person.
- Groups are on a free or a Pro tier. See [Tiers and cost](#tiers-and-cost).

## Who is alerted

The app shares requests out fairly and prioritises the closest responder:

1. Only responders who are available now are considered.
2. If the group uses distance, the closest of them come first. Distance uses the caller's
   registered location, held on group members' phones and never sent on air.
3. Among responders at a similar distance, the one who has answered least recently comes first,
   so that the same person is not always called.
4. If nobody acknowledges within the group's escalation time, the next responder is added. The
   first ones are not dropped. Once the list runs out, the whole group and the coordinator are
   alerted. A request never closes or times out on its own.

Escalation comes after 2 minutes for red and 15 minutes for amber, adjustable per group.

## Messages

- Red or amber goes out the moment it is pressed, with nothing else in it but the unit number,
  the colour and a message number.
- Any follow-up (a category such as "fallen", or free text) goes as a separate message carrying
  the same request number. The responder app assembles them into one request.
- Free text and details go only over the internet route, end-to-end encrypted. Over the mesh
  only the unit number, colour, category code and request number are sent.
- Red and amber are sent at once over every route that works without the caller's help, not
  just the first, and the responder app removes duplicates by request and message number. This
  replaces the "first route that works" order in [decision 8](design-decisions.md#d8). Mesh sends
  stay within the duty-cycle limit, so follow-ups go over the mesh only if no other route worked.
- A responder's acknowledgement goes back the same way. The caller sees "Seen by a responder"
  only after a human pressed acknowledge, and a cross if nothing could be sent at all.

## Routes

- **Internet:** see [How the internet route works](#how-the-internet-route-works).
- **SMS:** iOS does not let an app send an SMS on its own, so on iPhone SMS is not part of the
  first attempt. If every other route fails, the app offers a ready written text that the caller
  taps to send. Android sends automatically, as part of the first attempt.
- **Mesh:** the app sends through the paired Heltec board. A responder's phone paired with its
  own board receives the request over Bluetooth with no internet, and alerts them even when the
  app is in the background.

## How the internet route works

- Requests go end-to-end encrypted to a relay, which is a Cloudflare Worker. Pro groups also
  use a second, independent relay on a different provider, so that no single server or provider
  is needed.
- Each relay wakes responders' phones through Apple's and Google's push services, which is the
  only reliable way to wake an iPhone app.
- Responders' apps poll the relays when opened, in case a push was lost.
- The relays see only encrypted messages and unit numbers.

## Tiers and cost

- **Free:** must cost andeye nothing per group. It uses one relay within Cloudflare's free
  allowance, Apple's and Google's push services (free), and the mesh. If the free allowance runs
  out, the app shows a cross for the internet route, never a silent failure.
- **Pro:** a subscription. It adds the second relay and anything else that buys resilience. andeye
  pays for it, and Pro fees must more than cover what it costs.

## Alerts on the responder's phone

- Responder alerts need to sound through silent mode and Focus. On iPhone that needs Apple's
  Critical Alerts entitlement, granted on application. Apply for it with the fall-detection
  entitlement ([decision 18](design-decisions.md#d18)).
- Until it is granted, alerts are marked Time Sensitive, which gets through Focus but not silent
  mode, and the app tells responders so.

## Watch app

- Red, amber and green buttons, and the state of the last request.
- Sends through the phone, or directly over the watch's own mobile data if it has it.
- Does not replace the watch's own fall detection or emergency calling.

## Open questions

- Which provider runs the Pro second relay, and the Pro price.
- How the coordinator learns about rota gaps when they have no internet.
- How a unit's credentials and the group's encryption keys are created and shared at
  provisioning, and how a lost phone is removed.
- Whether distance-based priority is wanted where callers move, such as walkers, which would need
  live location over the internet route.
