> **O5.5 responses (Claude Opus 5.5, 2026-10-28).** Each finding below has an `O5.5 Fixed:` or
> `O5.5 Response:` line. The fixes are on `dev`, together with the home Wi-Fi commits this review
> could not see (`19504dd^..617f357`), so the requested range is now published for review. Core
> tests: 242 pass on macOS; relay: 30 pass. Conditional risks: the cross-group send epoch, a late
> relay poll after a group change, push-token registration before membership, and a newly paired
> watch's handover are fixed; notification capacity across groups, permission readiness, the APNs
> release environment, storage before first unlock and BLE recovery are agreed and listed in
> TODO.md for device work; notification-service keychain sharing waits on signing. Replay of a
> captured signed request is not fixed: a seen-signature store would add a write to every request
> against the free allowance and refuse legitimate identical retries, and frames are already
> de-duplicated.

# Scope, saved work and publication status

**This file now saves both the earlier main review and the completed review work on the available published application snapshot. Further review is paused at the user's request.** The application supplement below reviews [`dev` commit `640de64f9831681fbc7d6ce07ef194062c606247`](https://github.com/andeyePro/helpandeye/tree/640de64f9831681fbc7d6ce07ef194062c606247). The historical review afterwards covers `main` commit `1119a0377bbb1671c1cdfeafb595bbed439b5f8e`. All source links are pinned to the relevant commit; source line numbers are not report line numbers.

**The requested range `19504dd^..617f357` was unavailable and has not been reviewed.** Fresh published-ref fetches and local object/workspace searches did not supply those objects. Published `main` and `dev` remained at the commits above. The available 118-file development snapshot contains `Engine.swift`, phone/watch/Core code and the relay, but lacks the requested `app/helpandeyeCore/Sources/helpandeyeCore/HomeWiFi.swift` (`LocalWire.Session`), `app/helpandeye/HomeWiFi.swift` (four-second read confirmation), and `app/helpandeyeLocalPush/LocalPushProvider.swift` (locked-phone listener). Its manual checklist ends at section 35; the requested sections 41/42 are absent. `helpandeyeNotify/NotificationService.swift` is an APNs notification-service extension, not the missing local-push implementation. Findings below are confirmed or assessed **at `640de64`** and may already be fixed in the unavailable commits; they are not attributed to that requested range or claimed to describe the latest application.

**Publication:** the user authorised a commit and push containing only this report, on branch [`codex/review-report-2026-10-28`](https://github.com/andeyePro/helpandeye/blob/codex/review-report-2026-10-28/CodexReview.md). The delivery message identifies the actual published commit and confirms the push result. The temporary test harnesses and raw results described below are cloud review artifacts, not committed regression tests. No Mac copy is claimed by this file.

The completed findings, qualifications, observed results and coverage allocation from the development review are consolidated below. This is a bounded review of accessible code, not an exhaustive verification of every behaviour, Apple platform, device, network, interleaving or unpublished change. No Swift/Apple-native tests ran in this environment. The historical main-only report is preserved in full after the application supplement; its statements that the repository had no application describe its own earlier commit only.

# Published-development application supplement

**Snapshot:** `640de64f9831681fbc7d6ce07ef194062c606247`. **Date:** 28 October 2026, UTC/GMT. **Review material:** immutable source archive of all 118 Git-tree files, independently checked against Git blob IDs and SHA-256 hashes. The original checkout's source base remained `1119a037`; no application source was edited. Further review stopped when the user requested a pause; this section records work already completed, consolidated for the subsequently authorised publication.

The application has substantial implementations of group membership, signed calls and acknowledgements, responder-only encrypted personal messages, radio/relay routes, watch handover, APNs waking and UI. The most serious accessible-code issues concern relay bootstrap authority, revocation confidentiality, peer coordinator authority and malformed position decoding. Other findings affect watch delivery, failure reporting, settings distribution and route migration. Several are source-level or Apple API-contract findings; those are not presented as reproduced device incidents.

## Review method and limits

The Sol Extra High coordinator consolidated five reviewers: Astra Extra High for Core/state and relay/security, Terra Extra High for phone/watch/UI/configuration and mechanical execution, and an independent Astra Extra High challenger for specification consistency and high-impact claims. The parent separately read critical Core/relay/client paths, reran the relay policy probes and named tests, and challenged qualifications. All 23 Core source files, 19 Core test files, 15 phone Swift files, two watch files, two notification-extension files, UI tests, configuration, relay files and development documentation were assigned and read. The large model-vector JSONL fixture was parsed and replayed rather than manually auditing every byte as prose. Binary handling and inherited unchanged-file coverage are identified in the inventory.

Node 24 ran the real JavaScript relay logic using local storage, synthetic Ed25519 keys and explicit network stubs. No live APNs, paid model, Cloudflare deployment, account configuration, signup submission or external write was performed. No Swift, `swiftc`, Xcode, Apple SDK or XcodeGen executable was installed. The Core package unconditionally imports Apple Combine/CryptoKit and has no Linux replacement dependencies; an arbitrary Linux toolchain would not establish an unchanged native build. Consequently, the 201 statically inventoried Core XCTest methods and two UI-test methods were **not executed**. Documentation counts such as 165 Core/20 relay tests, and the user's count for unavailable commits, are not substituted for observed execution.

Severity below describes the consequence under the stated prerequisites, not exploit prevalence. “Source-confirmed” means the cited control flow establishes the issue but native execution remains unverified. “API-contract” adds platform dispatch/default semantics, still without device reproduction. No finding asserts regulatory or legal compliance or noncompliance.

## Prioritised findings at the available snapshot

### D1 — High: first relay registration does not require the primary coordinator's authorisation

**Confirmed by local execution; high confidence.** [Bootstrap validation](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L114) checks that the named primary public key hashes to the group ID, but [the list signer](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L134) may be a different key which lists itself as coordinator. A person who knows an uninitialised group's ID and primary public key can sign a membership list with their own key, name the real primary, and obtain a coordinator slot before the owner registers. An ordinary admitted member can possess those values through [the group membership/invitation data](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Group.swift#L399); this is not a claim that arbitrary outsiders can guess secret group material.

The local real-Ed25519 fixture observed `403` for a wrong-primary control and `403` for an uninvited coordinator after normal initial registration. In the first-registration case it observed `200`, then `200` for the owner's subsequent legitimate list which omitted the extra coordinator. The [merge of roles](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L129) preserved that extra key; it could subsequently add another key and read stored relay ciphertext. These are relay authorisation and availability/privacy-boundary failures, not a demonstration of decrypting responder-only content or forging a signed human acknowledgement.

**Fix:** require the group-root/primary key to sign initial registration, or require an explicit primary-signed delegation binding the registering key and group. Define authoritative versus incremental membership updates and a recovery path that removes unexpected roles. Preserve the wrong-primary and already-initialised negative controls in regression tests.

O5.5 Fixed: on first registration the relay now requires the signer to be the group's first coordinator (`relay/src/relay.js`); the old tests that let a second coordinator register first expected the bug and now expect 403.

### D2 — High: removal still permits fresh personal content to be encrypted for a removed responder

**Source-confirmed; high confidence in the key-flow contradiction, native execution unrun.** [Removal promises that a lost phone cannot read new traffic](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Group.swift#L223), but rotation retains previous secrets for a seven-day changeover. [Personal-message sealing](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/ForResponders.swift#L18) produces copies of every new note/position for both current and previous responder keys. [The personal send path](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L493) can put those copies on mesh when relay delivery fails. A removed/lost responder retaining the old responder private key and access to those ciphertexts can therefore decrypt fresh personal content even after the sender has accepted the removal and new key.

This is the updated sender's explicit seven-day compatibility window, not a statement that every stale sender stops after seven days, and not a claim that historical ciphertext becomes unreadable when a key expires. Existing [old-key compatibility tests](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/EngineTests.swift#L434) exercise compatibility, not exclusion of a revoked responder.

**Fix:** on responder removal, never encrypt new personal plaintext under retired responder keys. If old outer channels remain temporarily necessary, carry only content encrypted to the new responder key and state the availability tradeoff for devices awaiting an update. Add a removed-responder fixture which retains every old key and cannot decrypt any post-removal personal plaintext.

O5.5 Fixed: typed text, choices and position are sealed with the current responders' key only, never the old one kept during the changeover (`ForResponders.seal`). A responder who has not scanned their update sees the call but not those until they do; app spec updated to say so.

### D3 — High: peer membership controls can elect a new primary without primary approval

**Source-confirmed invariant failure; high confidence, native execution unrun.** [Member-add verification](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L739) accepts the control from an existing coordinator. [Applying that control](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Group.swift#L260) admits the supplied member number and coordinator role without enforcing an allocated number block or a primary-only promotion rule. [Primary selection](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Group.swift#L169) treats a missing block as zero and selects the minimum coordinator number. An existing secondary coordinator can therefore introduce a coordinator numbered zero; that peer becomes the selected primary and is then eligible for [primary-only removal/role controls](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L744).

This proves an unchecked peer-authority invariant in the available source. It does not automatically change the immutable group-ID/root binding used by the relay or establish a complete relay takeover. **Fix:** make primary identity explicit and root-authorised; validate allocated numbers and blocks, reject zero/out-of-block allocations, and require the current primary's authorisation for promotion or primary transfer. Test secondary-signed attempts to add number zero, steal another block and nominate a primary.

O5.5 Fixed: another coordinator's member-added is accepted only for callers and responders numbered inside that coordinator's own block (`Engine.swift`, signed membership branch); test adds number 0 as coordinator and a number in the first block.

### D4 — High: a malformed integer position can trap instead of being rejected

**Source-confirmed boundary defect; high confidence, native execution unrun.** [Position decoding](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/HelpFrame.swift#L214) calls `abs` on decoded `Int32` latitude/longitude before rejecting out-of-range values. `Int32.min` has no representable positive `Int32` value, so the checked Swift operation traps. The concrete entry is a decoded position frame with that integer field after whatever transport/group access and frame processing apply; this is not an anonymous-internet exploit claim or a `Double.nan` wire value. The position wire fields are integers.

**Fix:** compare directly against closed signed bounds, or widen to `Int64` before taking an absolute value. Add minimum/maximum integer, just-outside-coordinate-range, truncated and ordinary valid-frame decoding tests which assert rejection without process termination.

O5.5 Fixed: position decoding compares against closed signed ranges, no `abs`; test with `Int32.min` and the boundary.

### D5 — High: a watch-created call requests a WCSession delegate form the phone does not implement

**Apple API-contract/source finding; high confidence, device verification unrun.** [The watch creates its own call](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeWatch/WatchModel.swift#L281) and invokes `sendMessage` with `replyHandler: nil` and `errorHandler: nil`. [The phone implements only the reply-bearing receive-message delegate](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/PhoneWatchLink.swift#L72); no no-reply delegate was found. WCSession dispatches a no-reply message to the no-reply delegate, so that path cannot adopt the watch call through the implemented handler. With watch internet unavailable but the reachable phone's mesh route usable, the intended phone relay of the watch call is lost.

[The adoption test](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/WatchCompanionTests.swift#L78) directly calls the engine and bypasses this bridge, so it does not cover this defect. **Fix:** use the matching delegate form or provide a reply handler, explicit timeout/error handling, retry and idempotent adoption. Verify on paired hardware with watch internet disabled and phone mesh available; do not turn WCSession handoff into a human acknowledgement.

O5.5 Fixed: the watch sends its call with a reply handler, so the phone's reply-taking delegate receives it. Not checked on paired hardware.

### D6 — Medium: Unicode note splitting can make no progress and hang the caller path

**Source-confirmed; high confidence, native execution unrun.** [The note splitter](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Requests.swift#L79) repeatedly takes a fitting prefix and [drops that prefix](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Requests.swift#L89). [`MeshText.fit`](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/HelpFrame.swift#L405) returns an empty string if the first Swift `Character` exceeds the byte budget. With a 56-byte budget, one grapheme consisting of `e` plus 30 combining acute accents is 61 UTF-8 bytes; dropping zero characters leaves the loop unchanged. [`addNote`](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L475) invokes this synchronously on the engine's actor path.

**Fix:** guarantee progress or explicitly reject a single oversized grapheme with a useful error. Test combining sequences and joined emoji around the byte limit, and require bounded completion and byte-safe chunks. No actual Swift UI freeze was executed here.

O5.5 Fixed: a character bigger than a piece is cut between code points, so the splitter always progresses and loses nothing; test with `e` plus 30 combining accents.

### D7 — Medium: a reachable phone hides calls known only to the watch

**Source-confirmed; high confidence, native execution unrun.** [The watch's open-call selection](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeWatch/WatchModel.swift#L257) returns `phoneOpen` whenever the phone is reachable, discarding the watch engine's own open calls. Yet [Alert selection](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeWatch/WatchModel.swift#L165) and [watch-owned delivery](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeWatch/WatchModel.swift#L392) allow a watch-only call which the phone has not heard to alert. [The details/acknowledgement UI](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeWatch/WatchApp.swift#L107) is built from the selected open list, so the watch can alert with no corresponding actionable entry until state catches up or reachability changes.

**Fix:** merge phone/watch calls by group, caller and request identity; route the acknowledgement through whichever engine owns the call, and reconcile duplicates without fabricating receipt. Exercise asymmetric relay views with WCSession reachable.

O5.5 Fixed: with the phone in reach the watch shows the phone's calls plus any only it has heard, matching which of its alerts ring.

### D8 — Medium: foreground phone alerts have no presentation delegate

**Apple API-contract/source finding; high confidence, native execution unrun.** [Responder alerts](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Alerts.swift#L26) are submitted through `UNUserNotificationCenter.add`, but no `UNUserNotificationCenterDelegate`/`willPresent` implementation was present. Foreground notification banners and sounds are suppressed by default unless the application requests presentation. A visible list/badge can still change; this finding does not claim there is no visual indication. Watch suppression based on phone-known calls can compound the lack of an audible alert.

**Fix:** define and implement the intended foreground alert behaviour, respecting permission/focus policy and without implying a responder has accepted. Test foreground, background, locked, permission-denied and silent/focus configurations on actual devices.

O5.5 Fixed: phone and watch set a notification-centre delegate that presents banner, sound and list while Help&I is open. Not checked on devices.

### D9 — Medium: location UI announces “sent” before any route result exists

**Source-confirmed; high confidence.** [The location action](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/CallView.swift#L193) invokes `sharePosition` and moves to a shared state; [the resulting text](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/CallView.swift#L201) says “Where you are was sent.” [The engine's guard](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L469) accepts a configured or ready transport, while [the actual personal send](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L481) is spawned asynchronously and reports no result to this UI. A configured offline relay and unavailable box can fail after the success copy has already appeared.

**Fix:** expose pending/attempted, route-submitted and failed outcomes to the UI, and reserve receipt language for its actual evidence. Test both routes unavailable, one successful submission, timeout and retry. A route submission must remain distinct from a human acknowledgement.

O5.5 Fixed: "Sending where you are…" until a route takes it, then "was sent" or "could not be sent. Try again, or call 999." `sendPersonal` now reports whether any route took it.

### D10 — Medium: remote removal from the primary group hides other valid groups' responder UI

**Source-confirmed; high confidence, native execution unrun.** [The root view](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/HelpAApp.swift#L50) falls back to welcome when `model.me` is absent. [A valid received membership removal](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L739) can clear primary membership through [group application](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Group.swift#L270), while other engines/groups remain. The user can therefore lose the normal route to respond/acknowledge in other groups even though those memberships and alerts remain. [The voluntary-leave guard](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/GroupViews.swift#L243) does not cover remote removal.

**Fix:** choose the application's root from all valid memberships and provide recovery/other-group navigation after primary removal. Also review availability controls: [the UI availability action](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/AppModel.swift#L117) changes the primary engine, while [availability is per group](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L913); additional-group membership can therefore remain available without a matching visible control. Test remote primary removal while another group has an open call.

O5.5 Fixed: removed from the first group but still in others, the app shows Respond for those plus the join/create screen; "not available" now applies in every group the person responds in. Which group becomes first after such a removal is an open question for Martin (TODO T3).

### D11 — Medium: relay-address migration sends its announcement to the new address and reuses old registration state

**Source-confirmed; high confidence, native execution unrun.** [Changing settings](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L230) stores/configures the new relay URL before sending the update. [Transport configuration](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L305), [the relay base URL](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Relay.swift#L23) and [optional sending](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L525) therefore point the announcement at the new endpoint, while existing members continue polling the old endpoint. This conflicts with [the UI's old-address migration explanation](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/GroupViews.swift#L410).

Separately, [`publishedList`/publication timing/refusal state](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L159) is not keyed by endpoint. [Publication deduplication](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L609) can skip registering an unchanged member list at the new relay for 24 hours; a cached refusal for the same list can suppress it longer. **Fix:** preserve the old endpoint for the migration announcement or publish to both during an explicit transition, and scope/reset registration state per endpoint. Surface failures and test old/new endpoint partitioning and cached-success/refusal controls.

O5.5 Fixed: a changed relay address is sent over the old address first, then the phone moves; the published/refused member-list state is reset so the group registers afresh at the new address. Test checks the order.

### D12 — Medium: accepted group settings can exceed both transport envelopes

**Source/wire-budget finding; high confidence, native crypto execution unrun.** [Settings encoding](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/GroupSettings.swift#L20) permits 1,024 JSON bytes. [The signed settings frame](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/HelpFrame.swift#L169) adds 73 bytes. [ChaChaPoly combined data and Base64](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/RelayProtocol.swift#L26) add a 12-byte nonce, 16-byte tag and Base64 expansion; [the relay's 512-byte body limit](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L12) therefore permits at most 356 plaintext bytes, or 283 settings-JSON bytes. [The mesh payload ceiling of 165 bytes](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/HelpFrame.swift#L90) leaves only 92 settings-JSON bytes before any additional mesh constraints. Ordinary legal values in [button wording limits](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/ButtonWords.swift#L6) and [the settings editor](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/GroupViews.swift#L458) can exceed these budgets, including three 40-character labels and a 160-character note.

The settings update is stored locally, while [send failure is not surfaced](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L236); members need not receive what the UI says is distributed. **Fix:** define one transport-aware bounded encoding or authenticated chunking/reassembly protocol, enforce it before saving, and report distribution failure. Add exact envelope-boundary tests for multibyte labels, signatures, encryption and Base64, not just JSON size.

O5.5 Response: mostly superseded at the current commit. Settings are now zlib-compressed with a 2,048-byte cap, and the relay body limit is 4,096, so any frame that can be made fits the relay after sealing and base64; the mesh carries settings only when they fit, and otherwise they go over the internet or home Wi-Fi. The remaining gap was real: settings too big to make a frame were saved yet never sent. Now that change is refused with a plain message on the profile screens (test added).

### D13 — Medium: APNs failure is discarded and resend does not repeat the wake

**Confirmed by mocked local integration; high confidence in local decision paths.** [APNs submission](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/apns.js#L49) returns status/failure results, but [the worker discards them](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/worker.js#L61) while accepting stored ciphertext. [The client treats the HTTP success as sent](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Relay.swift#L67); [later resending](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L680) only supplies the wake when the earlier internet route was not already marked sent. In the synthetic fixture, APNs returned `503`, the message POST returned `200`, and a resend returned `200` with no second wake attempt: push-attempt count remained one.

Ciphertext remains available for polling, foreground opening or another route; this is not a demonstrated Apple outage or message deletion. **Fix:** queue bounded wake retries with backoff and token-error handling, distinguish stored ciphertext from wake success, and test transient/permanent APNs failures without converting wake submission into delivery or acknowledgement.

O5.5 Fixed: the relay awaits its pushes and answers `woke: false` when every wake failed transiently, and drops tokens APNs calls dead; the app then does not count the internet route as sent, so the next resend asks for the wake again. Not run against real APNs.

### D14 — Medium: cascade-removed relay members can be restored by a stale coordinator list

**Confirmed by local real-Ed25519 execution; high confidence.** [Coordinator removal](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L143) deletes dependent roles but does not tombstone those dependent keys. [Another coordinator's later merge](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L131) can reintroduce them from a stale list. The probe removed a coordinator and its dependent, restored the dependent with another admitted coordinator's stale list, and confirmed the explicitly removed coordinator remained blocked as a negative control.

**Fix:** if cascade removal is intended to be persistent, tombstone all removed dependent identities or use versioned authoritative membership decisions. Test stale-list orderings and ensure client and relay revocation models agree. This concerns relay membership; it does not itself grant new end-to-end keys.

O5.5 Fixed: keys dropped because their coordinator was removed are held in a separate set that only the owner's newest list clears, so a stale list from another coordinator cannot bring them back.

### D15 — Low: malformed authenticated requests escape the worker's controlled-error boundary

**Confirmed by local mocked worker execution; high confidence.** [Base64 validation](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L46) permits strings such as `A` which fail decoding, and [membership validation](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L107) dereferences malformed entries such as `null`. [The catch block](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/worker.js#L75) handles `RelayError`/`SyntaxError` but rethrows the resulting decoding/type errors. The additional worker fixture confirms the uncaught error, not a particular deployed Cloudflare HTTP response or a sustained outage.

**Fix:** validate element types and canonical decoding before use; convert all expected malformed-input errors to bounded `400` responses. Add malformed Base64, null/missing/wrong-type member and oversized-body tests through the actual worker entry point.

O5.5 Fixed: malformed base64, null or non-object members and a null message body give 400; new `relay/test/worker.test.js` drives the real worker entry.

### D16 — Low: the iOS screenshot test suppresses accessibility-audit execution errors

**Source-confirmed; high confidence, UI test unrun.** [`try? performAccessibilityAudit`](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeUITests/ScreensTests.swift#L109) discards thrown audit-operation errors, unlike [the watch test's recorded errors](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeWatchUITests/WatchScreensTests.swift#L54). Artifact writes also use ignored errors. This does not prove a clean accessibility audit or a specific inaccessible screen.

**Fix:** record/fail unexpected audit and screenshot-write errors explicitly, while documenting any intentional issue filters. Run the actual simulator/device suite and inspect artifacts; source inspection and YAML path checks are not a replacement.

O5.5 Fixed: an audit that cannot run, or a screenshot that cannot be saved, is recorded as a problem on both the iPhone and watch screen tests.

### D17 — Medium: health-category codes reach caller members despite the current privacy rule

**Implemented carry-forward policy mismatch; high confidence in source recipients.** [The privacy rule](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/AGENTS.md?plain=1#L53) prohibits medical information on the group mesh. [`followUp`](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L451) sends the raw category frame; [group-channel eligibility](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/HelpFrame.swift#L102) permits it, while [the personal-content split](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/HelpFrame.swift#L113) protects only notes and position. Caller members possessing the group key can therefore read health-category codes such as fallen/unwell.

The current [decision 12](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/docs/design-decisions.md?plain=1#L19) explicitly adopts responder-key-sealed group messages for typed text/position. That updated mechanism is legitimate and supersedes the old individual-DM mechanism requirement; it does not authorise health-category disclosure to caller members. **Fix:** settle the category privacy contract explicitly and, while the present prohibition stands, carry categories only in the responder-encrypted envelope. Add a caller-only recipient test for every category and personal field.

O5.5 Fixed, for Martin to confirm: a category the caller chose (Fallen, Unwell and the rest) now goes sealed for responders like typed text; only a missed check-in, raised by another member's phone, goes plainly. AGENTS.md, CONTRIBUTING.md and the app spec now say the caller's choice is personal content too.

### D18 — Low: design and manual-test documents contain conflicting current contracts and stale counts

**Confirmed documentary inconsistency; high confidence.** [The current responder-key decision](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/docs/design-decisions.md?plain=1#L19) differs from older individual-DM wording in [contribution rules](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/CONTRIBUTING.md?plain=1#L29), [the overview](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/README.md?plain=1#L89), [the application spec](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/docs/app-spec.md?plain=1#L57) and [architecture notes](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/docs/architecture.md?plain=1#L61). [Manual test 14](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/tests/MANUAL-TESTS.md?plain=1#L141) still expects a 96-byte DM rather than the implemented 56-byte personal pieces and sealed group transport. [Manual test 20](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/tests/MANUAL-TESTS.md?plain=1#L189) expects watch acknowledgement to fail while the phone is unreachable, contrary to the standalone watch route described elsewhere. These cannot all be used as independent correctness oracles.

[Status test totals](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/docs/prototype-status.md?plain=1#L8) are stale against the observed 22 named relay tests and static 201 Core methods; [claims about phone/screenshot execution](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/docs/prototype-status.md?plain=1#L25) also conflict with [later recorded device/simulator work](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/CHANGELOG.md?plain=1#L26). None establishes what ran in this environment. **Fix:** update one authoritative transport/privacy/watch contract, version the manual tests with it, separate historical evidence from current unrun gates, and regenerate counts from actual commands. The requested newer manual tests 41/42 are not in this snapshot and were not replaced by older tests.

O5.5 Fixed: the direct-message wording in AGENTS.md, CONTRIBUTING.md and the app spec now matches decision 12, manual tests 14 and 20 match the code, and the counts in prototype status are refreshed from this run.

## Conditional risks, readiness gaps and observations

These are saved separately because native runtime evidence, a platform configuration or an intended-policy answer is missing. They must not be promoted to observed device failures or latest-range regressions.

| Topic | Evidence and concrete condition | Assessment and recommendation |
|---|---|---|
| Cross-group asynchronous send epoch | [The primary engine is reused](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/AppModel.swift#L39) across leave/create/join. [Spawned jobs](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L191) survive [leave](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L286). [`addNote`](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L471) captures old plaintext pieces and awaits `sendPersonal` per piece; [each send reloads the current group](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L491). Hold the first send, leave/join a different group, then release it: later pieces can be encrypted to the new group's responder key. | High-consequence, source-supported interleaving risk; **no native disclosure executed**. New-recipient parser rejection of an old unit does not undo possession of decryption keys. Capture immutable group identity/epoch, cancel on transition, and recheck generation after every await. Test with a suspended first send and two synthetic groups. |
| Late poll/configuration result | [Polling captures old group/key state](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Relay.swift#L104), awaits a request and later invokes `onFrame`; configuration can change meanwhile. [Direct wake polling](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/AppModel.swift#L175) is not necessarily owned by the cancelled periodic task. | Same generation-boundary concern. URLSession cancellation may mitigate some paths, so do not claim every reconfiguration leaks a frame. Discard results whose captured identity/epoch no longer matches. |
| Push registration ordering | [Configure](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Relay.swift#L22) can start token registration before [membership publication](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L347); [push registration requires membership](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L172). [The registration result](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Relay.swift#L82) is ignored. | Existing-token startup can race to a `403`; actual Swift scheduling unrun. Retry after accepted membership and on bounded transient failures. |
| Notification capacity across groups | [Each engine independently budgets future notifications](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L885), while [the notification centre is shared](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/AppModel.swift#L133). Two groups can exceed the platform-wide pending-notification budget. | Native retention/eviction behaviour unverified. Allocate a global budget, prioritise current escalation and handle add errors. |
| Notification permission and critical alerts | [Permission-request results](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/AppModel.swift#L68) are not exposed as a phone readiness failure. [Critical sound selection](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Alerts.swift#L31) coexists with [time-sensitive entitlement configuration](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/project.yml#L27), not evidence of a Critical Alerts grant. | A readiness gap, not proof every notification fails. Inspect actual settings, show actionable readiness and test silent/focus/denied configurations. Critical Alerts requires an entitlement grant; external grant status was not established. |
| APNs release environment | [Development push entitlement configuration](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/project.yml#L27) and [release target settings](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/project.yml#L92) coexist with [a non-debug production APNs flag](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Relay.swift#L82). | Conditional signing/environment mismatch. Provisioning may override or reject it; do not claim all release builds fail. Bind environment to the signed entitlement and verify a real release archive/token. |
| Protected storage before first unlock | [Key retrieval](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Store.swift#L19) and [state loading](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Store.swift#L54) can return unavailable/default material; [the singleton](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/AppModel.swift#L10) has no observed protected-data reload path. [Save failures](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Store.swift#L72) and [callers](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/AppModel.swift#L60) need explicit handling. | Conditional OS-background-launch/recovery risk, not a demonstrated stale acknowledgement. Defer identity-changing work until protected storage is available, reload safely, and surface persistence failures. |
| Watch handover retry | [Handover data is marked handed](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/PhoneWatchLink.swift#L55) before transfer completion; [reactivation](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/PhoneWatchLink.swift#L65) does not clearly reset that cache for a failed transfer/new paired watch. | Device scenario unrun. Confirm receipt or retry/reset per session and pairing identity, without weakening key handling. |
| BLE connection recovery | [Service/characteristic discovery](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/BoardLink.swift#L365) does not visibly recover from every missing-service/error path. | Conditional stuck-connecting risk. Add explicit teardown/retry and callback-error tests on hardware/fakes. |
| Notification-service shared storage | [The extension configuration](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/project.yml#L44) and [shared-store lookup](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeNotify/SharedStore.swift#L9) leave keychain sharing unconfigured in this snapshot. | Explicit prototype readiness gap: generic push text can remain, richer decryption is unavailable until entitlements/configuration are supplied and tested. Do not portray known pending signing setup as an invented production incident. |
| Unauthorised rate-state persistence | [Rate limiting](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/worker.js#L59) persists state via [the per-key limiter](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L196) before [POST membership rejection](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L217). | The local probe confirmed a validly signed but unauthorised `403` leaves an `r:<key>` entry; invalid signatures leave none. Long-run quota/cost impact was not measured. Check membership before persistent per-member accounting and bound/prune state. |
| Public-key Base64 canonical form | [Key validation](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L26) and [decoding](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L48) admit pad-bit aliases which decode to identical bytes, while membership/removal maps use the original string. | Parent's local synthetic-key probe confirmed a **current coordinator** can admit an alias of a removed key and its existing private key authenticates that alias. Low robustness issue: a malicious current coordinator can already invite fresh keys; this is not an outsider authorisation bypass. Canonicalise encoded decoded bytes before every identity/map comparison. |
| Signed transport replay | [Timestamp/authentication acceptance](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L56) permits a captured valid request within the acceptance window to be stored again. | Local probe observed two stored copies. Existing application/frame deduplication limits impact; no forged acknowledgement was demonstrated. Consider request IDs/replay cache where appropriate and preserve idempotent frame processing. |

## Acknowledgement, call closure and privacy checks which were not inflated into findings

The available Core has meaningful protections: [acknowledgements require a current responding member](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Group.swift#L244); [outgoing acknowledgement receipt](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Requests.swift#L119) matches unit/request and applies a timestamp bound; [status selection](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Requests.swift#L125) distinguishes waiting/sent from seen. [Inbox pruning](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L657) does not simply expire every unacknowledged red/amber call, and [responder acknowledgement](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Requests.swift#L281) is an explicit action rather than an inferred transport result. [Re-acknowledgement](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L813) reuses a held signed acknowledgement, and [role checks](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L826) constrain acknowledgement generation. These were source cross-checked, not executed natively. No generic “transport success automatically closes a call” finding was asserted without code evidence.

The requested newer call-closing implementation, Home Wi-Fi session and four-second acknowledgement rule are absent, so their behaviour and interactions remain **unreviewed**. Direct engine tests cannot establish WCSession delivery or notification presentation. Similarly, physical acknowledgement buttons, radio-board behaviour and actual paired devices remain manual/hardware gates; documented planned hardware is not classified as a missing implementation defect merely because it is not present here.

## Executed evidence and what each result actually establishes

| Run | Observed result | Boundary |
|---|---|---|
| Existing `npm test` in `relay/` | Exit 0; Node reported four file-wrapper subprocess tests. | This wrapper count is not the named-case count. |
| `node --test --test-isolation=none --experimental-test-coverage test/*.test.js` | **22 named tests passed**, 0 failed/skipped. Parent independently repeated them. Four model-vector JSONL records replayed 159 publish steps; fixed Swift-generated signature verified and tampered data rejected. | Real relay logic; synthetic/local storage. Fixed vectors do not mean Swift was freshly executed. |
| Original relay suite's Node coverage | `apns.js`: 100% lines/branches/functions. `relay.js`: 99.28% lines, 94.29% branches, 97.87% functions; lines 74–75 uncovered. `worker.js` absent from that suite's coverage. | Tool-defined metric, not exhaustive input/interleaving coverage. |
| Added worker integration harness | **4/4 named cases passed**, including an assertion that a malformed request throws. Exercises worker routing/auth, JSON/size/method errors, membership, Meter warning, signed store/read, phone-visible/watch-quiet pushes and suppression of a third wake. | Map storage, synthetic keys and mocked fetch. No Cloudflare runtime, Apple delivery or real durable scheduling. A passing defect oracle is not evidence the defect is fixed. |
| Added worker harness's separate Node coverage | `worker.js` 100% lines/branches/functions; `apns.js` 97.26/87.50/100; `relay.js` 95.29/68.03/87.23. | Separate run. Maxima across runs were not combined into a fabricated union. |
| Relay policy/error probes | **8/8 scenario oracles passed**, independently repeated by parent. Demonstrated D1, D13, D14 and the rate/replay observations with negative controls. | Actual Group/GroupRelay fetch and Ed25519; local `503` stub, no external requests. These results include reproduced unsafe behaviour. |
| Dev site Chromium rerun | **49 checks: 48 passed, one failed** for already-established enlarged-text clipping. Default-font-32 at 320px also reproduced clipped content. | Actual browser, not native app UI. Normal mount/fallback and negative controls retained; artificial engine-throw injection is only resilience evidence. |
| Project/configuration inspection | PyYAML parsed `project.yml`; referenced paths/targets/package/config/scheme files exist. `bash -n tests/screens.sh` passed. | Not XcodeGen schema validation, compilation, signing or a screenshot run. Simulator script was not executed. |
| Sound regeneration | Generator output was byte-identical to both tracked WAVs: mono PCM16, 22,050Hz; not-sent 22,711 frames (~1.03s), seen 30,869 frames (~1.40s). | File/metadata/reproducibility only; audio was not listened to. |
| App lexical controls | Eight source-pattern/mutation controls completed. | Lexical checks only, mostly reflecting implementation shape; excluded from behavioural test totals and coverage claims. |
| Core and UI tests | 201 Core test methods and two UI-test methods statically inventoried, **zero executed here**. | Apple toolchain/framework/device boundary. No assertion of 201 passing tests or latest-range coverage. |

No aggregate “all tests passed” result is justified: the browser retains an actual failure, defect probes deliberately observe unsafe outcomes, and Swift/device checks remain unrun. Code coverage counts ordinary instrumented control flow; it does not cover all implicit exceptions, all values, scheduling, independent oracles or external-service semantics.

### Reproduction commands and retained artifact provenance

On an available copy of the pinned dev commit, the existing named relay suite is independently reproducible without package installation:

```sh
cd relay
node --test --test-isolation=none --experimental-test-coverage test/*.test.js
```

The other runs used temporary harnesses, **not committed maintained tests**. The following exact paths identify the completed cloud evidence; they will not survive indefinitely and are not files a Mac `git pull` will fetch:

- `/tmp/helpandeye-dev-mechanical/relay-tests-isolation-none.log`, `npm-test.log`, `worker.integration.mjs`, `worker-integration.log`, `project-inventory.log`, `test-names.txt` and `sound-output/`.
- `/tmp/helpandeye-dev-root-relay-named-tests.log` for the independent named-suite repeat.
- `/tmp/helpandeye-relay-security-640de64/probes.mjs` and `results.json`; harness SHA-256 `ad5fd7791e804f360c5498dc7c031f08d1ff2efa77e01fb34f449a102ccdbb8c`, result SHA-256 `f22beb81becf67c129c8961558a00a5075e0387f006406d87cf41ef444ade940`.
- `/tmp/helpandeye-independent-challenge/dev-page-suite-results.json`, `dev-page-suite.log`, `dev-browser-font-results.json` and screenshots.
- `/tmp/helpandeye-app-static-controls.py` and `helpandeye-app-static-controls-results.json`, lexical only.
- `/tmp/helpandeye-dev-640de64-manifest.json`, the 118-file source/blob/hash manifest, and immutable archive `/tmp/helpandeye-dev-review-640de64`.

The important additional-fixture semantics are saved in the findings above: D1 includes wrong-primary/existing-group controls and owner-recovery failure; D13 uses a stubbed `503` and counts wake attempts across resend; D14 distinguishes explicit tombstones from cascade deletion; D15 expects a controlled malformed-input response and instead observes a throw. Recreating those fixtures requires the pinned source, Map-like durable storage, fresh Ed25519 keys and a local fetch stub; no real account, token, device, push or public endpoint is needed.

## Remediation and still-unrun gates

First restore authorisation and confidentiality invariants: D1–D4, responder revocation and the group/epoch boundary. Then repair watch bridge/inbox, alert presentation, truthful status, migration and bounded settings; add regression tests at the actual adapters, not only direct engine calls. Align the changed responder-key design, category privacy and manual-test oracles before treating documentary expectations as acceptance criteria.

A macOS/Xcode run still needs the unchanged Core suite, UI/accessibility audits, build/signing and extension entitlements. Hardware gates include paired watch reachability asymmetry, notification focus/permissions/foreground presentation, before-first-unlock recovery, BLE error/disconnect/reconnect, multiple groups, revocation, relay migration and suspended-send leave/join races. Actual APNs and Cloudflare deployment semantics were not exercised. The unavailable requested commits and manual sections 41/42 must be supplied before their implementation can be reviewed. These are limitations of completed work, not claims that those systems failed.

## Development per-file coverage inventory

The inventory below covers **all 118 files** at `640de64`. “Inherited” means byte-identical to the earlier reviewed main snapshot and covered by that preserved review; it does not mean a new application-runtime test. Of the 30 main files, 23 were identical and seven changed; dev adds 88 files. Source/test reads are separate from execution. The model fixture was fully machine-parsed/replayed; the PNGs were visually inspected in the inherited review, and WAVs had metadata/regeneration checks without listening.

| Pinned file | Review coverage / evidence |
|---|---|
| [.github/claude/discussion-prompt.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/.github/claude/discussion-prompt.md?plain=1#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [.github/workflows/cla.yml](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/.github/workflows/cla.yml#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [.github/workflows/claude-discussions.yml](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/.github/workflows/claude-discussions.yml#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [.gitignore](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/.gitignore#L1) | Coordinator: full changed configuration read. |
| [.vss/sessions/2026-10-27T01-57-51Z.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/.vss/sessions/2026-10-27T01-57-51Z.md?plain=1#L1) | Independent Astra/specification: full text read; cross-document/current-contract challenge. |
| [.vss/sessions/2026-10-28T02-02-44Z.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/.vss/sessions/2026-10-28T02-02-44Z.md?plain=1#L1) | Independent Astra/specification: full text read; cross-document/current-contract challenge. |
| [AGENTS.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/AGENTS.md?plain=1#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [CHANGELOG.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/CHANGELOG.md?plain=1#L1) | Independent Astra/specification: full text read; cross-document/current-contract challenge. |
| [CLA.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/CLA.md?plain=1#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [CONTRIBUTING.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/CONTRIBUTING.md?plain=1#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [CONTRIBUTORS.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/CONTRIBUTORS.md?plain=1#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [LICENSE](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/LICENSE#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [README.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/README.md?plain=1#L1) | Independent Astra/specification: full text read; cross-document/current-contract challenge. |
| [TODO.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/TODO.md?plain=1#L1) | Independent Astra/specification: full text read; cross-document/current-contract challenge. |
| [app/.gitignore](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/.gitignore#L1) | Terra/app + mechanical and coordinator: full config read; path/YAML checks where applicable; native build unrun. |
| [app/Signing.xcconfig](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/Signing.xcconfig#L1) | Terra/app + mechanical and coordinator: full config read; path/YAML checks where applicable; native build unrun. |
| [app/helpandeye/Alerts.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Alerts.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/AppModel.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/AppModel.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/BoardLink.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/BoardLink.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/BoxView.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/BoxView.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/CallView.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/CallView.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/CallerVoice.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/CallerVoice.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/Colours.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Colours.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/Display.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Display.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/GroupViews.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/GroupViews.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/HelpAApp.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/HelpAApp.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/PhoneWatchLink.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/PhoneWatchLink.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/QR.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/QR.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/Relay.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Relay.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/RespondView.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/RespondView.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeye/Sounds/not-sent.wav](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Sounds/not-sent.wav#L1) | Terra/app + mechanical: PCM metadata; generator byte-match; not listened. |
| [app/helpandeye/Sounds/seen.wav](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Sounds/seen.wav#L1) | Terra/app + mechanical: PCM metadata; generator byte-match; not listened. |
| [app/helpandeye/Store.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeye/Store.swift#L1) | Terra/app: full source read; relevant security/transport paths cross-read; native execution unrun. |
| [app/helpandeyeCore/Package.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Package.swift#L1) | Terra/app + mechanical and coordinator: full config read; path/YAML checks where applicable; native build unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/Airtime.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Airtime.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/ButtonWords.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/ButtonWords.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/CallerFeedback.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/CallerFeedback.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/ChannelPlan.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/ChannelPlan.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/CheckIn.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/CheckIn.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/CommandQueue.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/CommandQueue.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Engine.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/Escalation.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Escalation.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/ForResponders.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/ForResponders.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/Group.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Group.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/GroupSettings.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/GroupSettings.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/HelpFrame.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/HelpFrame.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/MeshCore.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/MeshCore.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/MeshHub.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/MeshHub.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/PushText.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/PushText.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/RelayPoll.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/RelayPoll.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/RelayProtocol.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/RelayProtocol.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/Requests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Requests.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/Resend.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Resend.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/Rota.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/Rota.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/RoutePlan.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/RoutePlan.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/StatusWords.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/StatusWords.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Sources/helpandeyeCore/WatchHandover.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Sources/helpandeyeCore/WatchHandover.swift#L1) | Astra/Core: full source read; security-critical paths independently challenged; native execution unrun. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/CallerFeedbackTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/CallerFeedbackTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/CheckInTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/CheckInTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/CommandQueueTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/CommandQueueTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/EngineFuzzTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/EngineFuzzTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/EngineTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/EngineTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/EscalationTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/EscalationTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/GroupTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/GroupTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/HelpFrameTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/HelpFrameTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/MeshCoreTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/MeshCoreTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/MeshHubTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/MeshHubTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/PushTextTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/PushTextTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/RelayModelTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/RelayModelTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/RelayPollTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/RelayPollTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/RelayProtocolTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/RelayProtocolTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/RelayVectorTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/RelayVectorTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/RequestTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/RequestTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/ResendTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/ResendTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/StatusWordsTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/StatusWordsTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeCore/Tests/helpandeyeCoreTests/WatchCompanionTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeCore/Tests/helpandeyeCoreTests/WatchCompanionTests.swift#L1) | Astra/Core or relay: full test-source read; included in static 201-method inventory; not executed. |
| [app/helpandeyeNotify/NotificationService.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeNotify/NotificationService.swift#L1) | Terra/app + Astra/relay: full source read; API/configuration boundaries reviewed; native execution unrun. |
| [app/helpandeyeNotify/SharedStore.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeNotify/SharedStore.swift#L1) | Terra/app + Astra/relay: full source read; API/configuration boundaries reviewed; native execution unrun. |
| [app/helpandeyeUITests/ScreensTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeUITests/ScreensTests.swift#L1) | Terra/app + mechanical: full source read; no simulator/device run. |
| [app/helpandeyeWatch/WatchApp.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeWatch/WatchApp.swift#L1) | Terra/app + Astra/relay: full source read; API/configuration boundaries reviewed; native execution unrun. |
| [app/helpandeyeWatch/WatchModel.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeWatch/WatchModel.swift#L1) | Terra/app + Astra/relay: full source read; API/configuration boundaries reviewed; native execution unrun. |
| [app/helpandeyeWatchUITests/WatchScreensTests.swift](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/helpandeyeWatchUITests/WatchScreensTests.swift#L1) | Terra/app + mechanical: full source read; no simulator/device run. |
| [app/project.yml](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/app/project.yml#L1) | Terra/app + mechanical and coordinator: full config read; path/YAML checks where applicable; native build unrun. |
| [assets/brand/README.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/assets/brand/README.md?plain=1#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [assets/brand/gen_mark.py](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/assets/brand/gen_mark.py#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [assets/brand/svg/help-mark-panel.svg](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/assets/brand/svg/help-mark-panel.svg#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [assets/brand/svg/help-mark-white.svg](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/assets/brand/svg/help-mark-white.svg#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [assets/brand/svg/icon-ios-any.svg](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/assets/brand/svg/icon-ios-any.svg#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [assets/brand/svg/icon-ios-dark.svg](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/assets/brand/svg/icon-ios-dark.svg#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [assets/brand/svg/icon-ios-tinted.svg](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/assets/brand/svg/icon-ios-tinted.svg#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [assets/brand/svg/icon-mac-any.svg](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/assets/brand/svg/icon-mac-any.svg#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [assets/brand/svg/icon-mac-dark.svg](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/assets/brand/svg/icon-mac-dark.svg#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [assets/brand/svg/icon-whatsapp.svg](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/assets/brand/svg/icon-whatsapp.svg#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [docs/app-spec.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/docs/app-spec.md?plain=1#L1) | Independent Astra/specification: full text read; cross-document/current-contract challenge. |
| [docs/architecture.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/docs/architecture.md?plain=1#L1) | Independent Astra/specification: full text read; cross-document/current-contract challenge. |
| [docs/design-decisions.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/docs/design-decisions.md?plain=1#L1) | Independent Astra/specification: full text read; cross-document/current-contract challenge. |
| [docs/prototype-status.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/docs/prototype-status.md?plain=1#L1) | Independent Astra/specification: full text read; cross-document/current-contract challenge. |
| [relay/.gitignore](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/.gitignore#L1) | Astra/relay + Terra/mechanical/coordinator: full text/config read; no deployment. |
| [relay/README.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/README.md?plain=1#L1) | Astra/relay + Terra/mechanical/coordinator: full text/config read; no deployment. |
| [relay/package.json](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/package.json#L1) | Astra/relay + Terra/mechanical/coordinator: full text/config read; no deployment. |
| [relay/src/apns.js](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/apns.js#L1) | Astra/relay + Terra/mechanical + parent: full read; existing named tests and added local integration/probes. |
| [relay/src/relay.js](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/relay.js#L1) | Astra/relay + Terra/mechanical + parent: full read; existing named tests and added local integration/probes. |
| [relay/src/worker.js](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/src/worker.js#L1) | Astra/relay + Terra/mechanical + parent: full read; existing named tests and added local integration/probes. |
| [relay/test/apns.test.js](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/test/apns.test.js#L1) | Astra/relay + Terra/mechanical: full read and actual named Node test execution. |
| [relay/test/interop.test.js](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/test/interop.test.js#L1) | Astra/relay + Terra/mechanical: full read and actual named Node test execution. |
| [relay/test/model-vectors.jsonl](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/test/model-vectors.jsonl#L1) | Terra/mechanical and relay: all four JSONL records parsed; 159 publish steps replayed; not manual prose audit. |
| [relay/test/model.test.js](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/test/model.test.js#L1) | Astra/relay + Terra/mechanical: full read and actual named Node test execution. |
| [relay/test/relay.test.js](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/test/relay.test.js#L1) | Astra/relay + Terra/mechanical: full read and actual named Node test execution. |
| [relay/wrangler.jsonc](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/relay/wrangler.jsonc#L1) | Astra/relay + Terra/mechanical/coordinator: full text/config read; no deployment. |
| [site/andeye-eye.js](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/site/andeye-eye.js#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [site/apple-touch-icon.png](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/site/apple-touch-icon.png#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [site/favicon.svg](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/site/favicon.svg#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [site/index.html](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/site/index.html#L1) | Independent Astra: full changed-copy read and real Chromium rerun; 48/49 checks pass. |
| [site/og.png](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/site/og.png#L1) | Inherited byte-identical main review; pinned development copy compared. |
| [tests/MANUAL-TESTS.md](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/tests/MANUAL-TESTS.md?plain=1#L1) | Independent Astra/specification: full text read; cross-document/current-contract challenge. |
| [tests/screens.sh](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/tests/screens.sh#L1) | Terra/mechanical: full read and bash syntax check; simulator/reset actions not run. |
| [tests/tools/make-sounds.py](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/tests/tools/make-sounds.py#L1) | Terra/mechanical: full read, executed outside checkout; both outputs byte-identical. |
| [wrangler.jsonc](https://github.com/andeyePro/helpandeye/blob/640de64f9831681fbc7d6ce07ef194062c606247/wrangler.jsonc#L1) | Inherited byte-identical main review; pinned development copy compared. |

The archive's 118 files were independently verified against the published Git tree; original main source hashes were unchanged during review. Only `CodexReview.md` is authorised for repository modification/publication. This supplement preserves the completed accessible-source work and its unresolved limits; it does not convert unavailable code or unrun Apple tests into reviewed behaviour.

**Pre-publication document audit:** all 475 pinned source-file links resolved to the reviewed local snapshots and their cited text-line numbers were within file bounds. The 118 development inventory entries matched the source manifest exactly. SHA-256 checks found no changes to the 30 original main files or the 118 archived development files; all 14 historical artifact hashes and the two recorded relay-probe hashes matched. Markdown fences/details were balanced and no trailing whitespace was found. These are document/provenance checks, not additional application execution or a semantic verification of every citation.

---

<details>
<summary>Historical main-only review at 1119a037 — preserved complete report and earlier verification</summary>

# Help&I repository review

**Reviewed commit:** `1119a0377bbb1671c1cdfeafb595bbed439b5f8e`

**Review date:** 28 October 2026, UTC (also GMT in Europe/London)

**Scope:** all 30 files tracked at that commit: 28 text files and two PNGs. This report is an additional file, outside that inventory. Source citations below refer to the reviewed source files and their line numbers, not to lines in this report.

## Assessment

This is a small, explicitly pre-alpha design repository with a functioning static information site, two GitHub workflows, and brand assets. It contains no firmware, phone/watch application, responder console, relay implementation, package manifest, or automated product test suite. Their absence is consistent with [the stated design-stage status](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/README.md?plain=1#L7), rather than an implementation defect.

The most important confirmed design inconsistency is that the app specification permits **health-related category codes on the shared mesh channel**. A separate high-consequence design gap is the incomplete contract for delivery-failure feedback after a message has been submitted. These should be resolved before implementing the protocol or conducting reliance-based trials. They are not observed failures of an existing Help&I device or app.

The existing site has misleading unconditional reassurance and measurable text contrast failures. The Discussions bot can lose the triggering message and reply location in sufficiently long threads. A fresh reproduction also confirmed that the selected CLA action omits contributors who appear only after the first 100 pull-request commits. The brand generator reproduces its seven current outputs exactly, but an eighth tracked variant still contains the previous mark.

Follow-up behavioural verification found clipped explanatory text with a large browser font at a narrow viewport, and an animation scheduling error when the engine loads late. It exercised every explicit first-party JavaScript function literal and Python function definition, with measured coverage and failure/boundary cases described below. **All-file review is not exhaustive verification of all behaviour.** The justified claim is coverage of the enumerated functions, measured control-flow metrics and bounded scenarios, with real failures and remaining gaps stated explicitly.

No critical exploit, actual disclosure of user information, or actual emergency-service failure was demonstrated. This review does not establish safety certification, radio conformity, accessibility conformance for the entire site, legal enforceability, or production readiness.

| ID | Priority | Classification | Finding |
|---|---|---|---|
| F1 | High | Confirmed design inconsistency | Shared-channel category codes contradict the personal-content restriction |
| F2 | High consequence before implementation | Design gap, not a confirmed defect | Post-submission delivery-failure feedback is not specified |
| F3 | Medium | Confirmed public-copy defect | An answer is promised unconditionally; route preconditions are omitted |
| F4 | Medium | Confirmed accessibility defect | Primary calls to action and small status/footer text have insufficient contrast |
| F5 | Medium | Confirmed automation defect | The Discussions bot truncates threads and can omit the current question and reply parent |
| F6 | Low | Confirmed asset consistency defect | WhatsApp artwork retains the superseded colour and cross and is not generated |
| F7 | Medium | Confirmed accessibility/layout defect | Large browser text is clipped at a narrow viewport |
| F8 | Low | Confirmed animation defect | Late loading makes blinking interrupt the initial draw |
| C1 | Medium | Confirmed dependency defect, conditional long-PR impact | CLA contributor checks stop after the first 100 commits |
| C2 | Medium | Confirmed dependency defect, conditional long-thread impact | CLA signing ignores signature comments beyond the first API page |

Here, **High** means a safety/privacy requirement must be resolved before implementing or relying on the planned product; it does not indicate a currently deployed emergency device vulnerability. **Medium** means a material problem with present information/automation or a significant integration condition. **Low** means limited maintenance or presentation impact. Confidence describes the evidence for the finding, separately from its consequence. Prospective risks and recommendations are listed separately below.

## Method and review boundaries

The review used Codex, with GPT-6.1 Sol at Extra High effort coordinating and writing this report; GPT-6 Astra at Extra High effort reviewed safety/specification and security/CI/governance, and performed an independent challenge pass; GPT-6.1 Terra at Extra High effort reviewed website/browser/accessibility and assets/reproducibility. The parent review agent separately checked cross-document evidence, static HTTP serving, image appearance, and repository integrity. Model names describe assigned roles, not a claim of independent human certification.

Reviewers read [AGENTS.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/AGENTS.md?plain=1#L1) and [CONTRIBUTING.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CONTRIBUTING.md?plain=1#L1) first. The team read every first-party text file in full and examined both binary assets through metadata, decoding and visual inspection. Findings were challenged against the actual source and the design-stage status. In particular, no automatic request closure, arbitrary shell access through bot questions, or missing-PAT defect was inferred without supporting code.

Checks ran against the reviewed checkout or temporary copies/scripts under `/tmp`. No original repository file was modified, no package was installed into the repository, and no workflow, deployment, pull request, discussion reply, commit or push was initiated. Verified HTTPS was retained for the limited upstream-source reads. The review did not change API, cloud or credential settings.

## Findings and safety design clarification

### F1 — Keep health-related categories off the shared mesh channel

**Priority: High · Confidence: High · Type: design inconsistency**

[The app specification gives “fallen” as a follow-up category](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L43), then says that calls and the group channel can carry a [category code](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L45). This conflicts with the restriction on [group-channel personal content](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/AGENTS.md?plain=1#L52), the [contribution privacy rule](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CONTRIBUTING.md?plain=1#L29), and [decision 12](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/design-decisions.md?plain=1#L19). The latter explicitly explains that the group key is shared by every member, and personal content is to use each responder's own key. The [latest changelog entry](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CHANGELOG.md?plain=1#L7) also says the group channel remains unit-number-only.

A code meaning “fallen” associated with a known unit conveys the same information as the corresponding word. People with the group key and a unit-to-person mapping could learn it even when they are not the selected responders. The finding concerns the **recipient boundary within the encrypted group**; it is not evidence of plaintext disclosure to arbitrary radio listeners. Non-personal transport fields such as colour and request identifiers are not the issue.

**Recommendation:** remove personal category codes from the broadcast schema. Explicitly decide whether caller-selected categories are allowed as individual encrypted follow-ups: the current exception literally permits caller-*typed* text and position, so merely moving preset categories to direct messages would still require a documented policy decision. Add packet-level acceptance checks that inspect every group-channel message type, including retries, status and follow-ups, and verify that personal categories and text appear only on the authorised individual route.

O5.5 Response: see D17 (fixed in the app).

### F2 — Specify what the failure cross can actually establish

**Consequence: High if left unresolved before reliance · Confidence: High in the missing contract · Type: design gap, not a confirmed implementation defect**

[The app specification](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L54) requires a cross “if nothing could be sent at all.” It does **not** say this is the only condition that shows a cross: the word “only” in the preceding clause governs human acknowledgement. The [agent safety rule](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/AGENTS.md?plain=1#L46), [decision 7](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/design-decisions.md?plain=1#L14), [README](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/README.md?plain=1#L106), and [site](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L190) also require feedback when delivery fails or a message does not get through. The site repeats that promise [near the closing caveat](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L251).

Local radio transmission or relay acceptance can succeed while no responder receives an alert. The specification itself anticipates [lost pushes that are recovered when the app next opens](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L72). It does not define what constitutes technical delivery, when delivery is unknown, or how those cases appear to the caller. The written contract therefore leaves an important post-submission state unresolved; it does not prove that a future implementation would suppress the cross. Conversely, a missing human acknowledgement does not prove technical non-delivery and must not be presented as such.

**Recommendation:** define separate states for local submission, technical receipt where measurable, unknown/failed delivery, and manual acknowledgement. State the evidence and bounds for each route, retries and honest caller wording, including what to do if no person responds. Timers may change a delivery-status indication or add responders; they must never acknowledge, close or expire the outstanding help request. Test “local send succeeds but every responder delivery fails,” lost acknowledgements, delayed receipts and partial success across routes. If “sent” was intended to mean end-to-end receipt, write that explicitly and demonstrate how each route establishes it.

O5.5 Response: agreed in substance and since implemented. The caller sees "sent" only once a route took the call (home Wi-Fi counts only when another member's Help&I confirms it read it within 4 s), "seen" only on a responder's signed acknowledgement, and the cross when no route took it; timers widen alerts but never acknowledge, close or expire a call (decision 6). See `StatusWords` and the app spec, What the caller sees.

### F3 — Remove unconditional reassurance and show route preconditions

**Priority: Medium · Confidence: High · Type: public-copy defect**

Under “What you can count on,” [the site says “A person always answers”](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L185). The planned escalation can [exhaust the whole group without acknowledgement](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L33), and the site's own [closing statement correctly makes help conditional on someone being there](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L251). The intended requirement is that a human confirms help; availability is not guaranteed. [“Someone is alerted straight away”](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L170) similarly states an outcome that depends on routes, devices, permissions and responders.

The route list also offers [other mobile networks without qualification](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L215), whereas the [README requires a multi-network SIM](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/README.md?plain=1#L80). On the first-release iPhone app, [SMS-only fallback requires the caller to tap Send](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L60); it is explicitly not an automatic initial route. The platform limitation is already documented, so this is a public-claim consistency problem, not a newly discovered iOS defect.

**Recommendation:** use a heading such as “A person confirms help,” describe the red button as starting a request, and put the essential route qualifications beside the route claims: alternate networks require supported service/SIM arrangements, and iPhone SMS fallback needs an additional tap. Keep a clear action when nobody acknowledges. Retain the existing emergency-services and pre-alpha notices. Those notices at [line 122](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L122), [line 132](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L132) and [line 139](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L139) reduce current reliance risk but do not make contradictory absolute statements accurate.

O5.5 Fixed: "A person confirms help"; Help "starts a call for help to the people you chose"; route qualifications for other networks and the iPhone's tap-to-send text.

### F4 — Improve contrast for calls to action and the readiness notice

**Priority: Medium · Confidence: High · Type: accessibility defect**

The [primary button style](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L65) uses white on `#009A44`: **3.68:1** contrast. Its [hover state](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L66) uses white on `#00B04E`: **2.87:1**. Computed styles confirm the buttons use 16 px, weight 700 text, which is below the size threshold for the 3:1 large-text exception. These pairs do not meet the WCAG 2.x AA 4.5:1 normal-text criterion.

The [fine-print style](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L69) and [footer](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L106) use `#6A7382` on `#0C0F16`: **4.00:1**, also below 4.5:1 for their small text. This affects the safety-relevant [“Nothing here is ready to rely on yet” notice](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L132), as well as footer text. Green text on the card background was checked separately and passes at approximately 4.81:1; the brand green need not be changed everywhere.

**Recommendation:** choose a darker button background or suitably dark button text for both normal and hover states, and lighten faint text sufficiently. Recheck every interactive state and real composited background after changing tokens. Preserve a visible keyboard focus indication. The finding is the measured text contrast failure, not a claim that a complete WCAG audit was performed.

O5.5 Fixed: dark text on the green buttons (5.21:1, hover 6.68:1); faint text lightened to at least 5.73:1.

### F5 — Fetch the triggering discussion message independently of pagination

**Priority: Medium · Confidence: High · Type: automation correctness defect**

The [thread query](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L37) fetches only `comments(first:100)` and `replies(first:100)` without pagination. Both the [prompt's marker for the triggering comment](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L42) and [reply-parent lookup](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L49) depend on that truncated result. If the current comment is the 101st top-level comment, or the 101st reply under a comment, it can be absent from the prompt; the lookup produces an empty parent and [the posting step adds a new top-level comment](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L83).

An offline fixture using the workflow's actual `jq` expressions confirmed that the 100th message is marked and parented correctly, while the 101st comment/reply has no trigger marker and no reply parent. This is a deterministic limit, not an observed failure in a live thread. Long discussion history can also create an oversized prompt even before that limit.

**Recommendation:** fetch the triggering node and its top-level parent directly from the event/node ID, then fetch a bounded, relevant context window or paginate the history deliberately. Assert that exactly one triggering message is present before invoking the model, and fail safely if its parent cannot be determined. Add fixtures for a discussion-body mention, comment, nested reply, deleted author and the pagination boundaries. Bound the context size independently of comment count.

O5.5 Fixed: the triggering comment and its parent are fetched by node ID; the job fails safely if either is missing.

### F6 — Regenerate or deliberately retire the legacy WhatsApp mark

**Priority: Low · Confidence: High · Type: asset consistency defect**

The [brand README](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/README.md?plain=1#L3) specifies safety green `#009A44` and a square-ended cross of five equal squares, and [instructs running the generator to regenerate `svg/`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/README.md?plain=1#L7). The [generator CLI](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L135) writes seven variants, all freshly reproduced byte-for-byte. The eighth tracked variant, [icon-whatsapp.svg](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/svg/icon-whatsapp.svg#L4), retains `#2E7D32` and a thin rounded plus. The [changelog records replacing that older colour and shape](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CHANGELOG.md?plain=1#L38).

**Recommendation:** generate the WhatsApp variant from the same current geometry, or explicitly document its intended legacy appearance and separate source. A fresh directory containing only the generator should reproduce every asset advertised as generated. No current site reference to this variant was found, so this is a brand/maintenance issue rather than a site runtime or safety failure.

O5.5 Fixed: `gen_mark.py` now generates the WhatsApp icon from the current geometry.

### F7 — Allow the button explanations to reflow with enlarged browser text

**Priority: Medium · Confidence: High · Type: accessibility/layout defect**

At a 320×568 CSS-pixel viewport with Chromium's default font preference set to 32 px, the three button-explanation cards extend to approximately x=348.98; actual text glyphs extend beyond the viewport to x=327.98. The [body clips horizontal overflow](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L30), so part of “Someone is alerted straight away” and “Lets everyone know you are fine” is hidden. The [grid/flex card layout](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L93), [fixed gaps and padding](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L94), and [non-shrinking rem-sized dots](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L96) leave insufficient room for the text.

This was reproduced using unchanged HTML/CSS with both a fresh Chromium profile's default-font setting and the independent CDP `Page.setFontSizes` setting. An earlier injected root-font-size probe led to the discovery but is not the sole evidence. A 16/24/32 px default-font × 320/375 px viewport matrix failed only at 320+32 among those six cases. Ordinary 320 px rendering without enlarged text passes. No actual browser-zoom or OS text-scaling result is claimed.

**Recommendation:** let these cards wrap or stack the dot and text, allow grid/flex children to shrink appropriately, and verify actual glyph visibility at 200% default text size in a 320 px viewport. Removing overflow clipping alone would hide the underlying layout problem behind horizontal scrolling. Retest normal, enlarged-text and keyboard-focus layouts after the change.

O5.5 Fixed in CSS (cards wrap, grid children may shrink). Screenshotted at 320 px wide; not yet checked with a 32 px default font.

### F8 — Base the first blink deadline on the animation's own start time

**Priority: Low · Confidence: High · Type: animation sequencing defect**

The engine sets [the first blink deadline to 1,800–4,300 ms](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L257), then compares it to [the absolute requestAnimationFrame timestamp](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L260). In contrast, [the draw-on animation measures elapsed time from its own first frame](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L243). Mounting after navigation has already lasted over 4.3 seconds starts a blink during the intended 1.2-second draw. [The blink's `setWink`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L236) calls `setPose` without a draw progress value, which [reveals the iris and clears the unfinished stroke's dash/visibility state](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L203). Subsequent draw callbacks can hide them again.

Independent deterministic and natural-rAF reproductions observed the full iris/outlines within the first two frames of a late mount, followed by a return to an incomplete draw. Early mounting, `blink:false`, and an in-memory relative-deadline correction are controls. The [blocking external script in the page head](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L20) makes slow loading a relevant trigger for the [page's normal draw-on mounts](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L290). This is a presentation defect, not a failure of a help request or hardware alert.

**Recommendation:** schedule the initial blink relative to the mount/first-frame clock, and coordinate blinking with draw completion so that two animation loops cannot overwrite one another's pose. Add a late-load regression case. A separate first-frame timestamp of exactly zero also exposes a truthiness sentinel in `drawStart`; that was a synthetic boundary diagnostic and is not promoted to a separately demonstrated real-browser defect.

O5.5 Fixed: the first blink is timed from the eye's own first frame and waits for the draw to finish.

## Conditional integration finding

### C1 — The selected CLA action omits contributors after the first 100 commits

**Priority: Medium · Confidence: High · Type: confirmed upstream defect with conditional long-PR impact**

The repository selects [CLA Assistant v2.6.1](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L20). The fetched tag resolved to commit `ca4a40a7d1004f18d9960b404b97e5f30a505a08`. Its [contributor query fetches only the first 100 pull-request commits](https://github.com/contributor-assistant/github-action/blob/ca4a40a7d1004f18d9960b404b97e5f30a505a08/src/graphql.ts#L15). Although it requests `hasNextPage` and `endCursor`, it [processes that single page and returns](https://github.com/contributor-assistant/github-action/blob/ca4a40a7d1004f18d9960b404b97e5f30a505a08/src/graphql.ts#L54), without fetching the remainder or rejecting an incomplete list.

If all contributors in the first page have signed but a new unsigned contributor appears only in a later commit, that person is absent from the list checked against the ledger. This can defeat the intended contributor-signing gate for a pull request exceeding 100 commits. No existing unsigned contribution or live workflow bypass was demonstrated.

An offline fixture executed the **actual bundled contributor-enumeration module** with a response reporting `totalCount:101`, `hasNextPage:true` and 100 commits by an already signed contributor. The function made one GraphQL call and returned only that contributor, never requesting the second page. An independent integration fixture then loaded the actual contributor, comment-decision and full CLA-setup modules: an unsigned author at commit 101 reached “All contributors have signed the CLA” with no failure; moving that author into commit 100 produced a failure and signature-request comment. The coordinator independently reran both fixtures and read the complete source path. These fixtures stub external APIs and do not represent an executed live signing operation.

**Recommendation:** use a reviewed revision that paginates all commits, or fail closed when the result is incomplete; pin the reviewed commit SHA. Add a fixture with an unsigned contributor beyond the first page and exercise the complete sign/recheck flow in a controlled repository. Same-repository storage with `GITHUB_TOKEN` is supported; no missing-PAT defect was found.

**Withdrawn hypothesis:** a separate initial “missing ledger cannot bootstrap because 404 is numeric” experiment omitted the dependency's HTTP wrapper, which merges parsed REST error JSON into the error object and can overwrite the status with a string. A raw-file 404 does not establish that API error body's shape. The independent challenge pass found this omission, so no bootstrap failure is asserted. This illustrates the limit of that initial fixture rather than adding an unresolved defect to the findings.

O5.5 Response: disagree for now. Upstream, including its latest commit, has no paginated revision to move to; the action is pinned to v2.6.1's SHA. With one contributor, PRs over 100 commits are unlikely; revisit if that changes.

### C2 — The CLA action does not read a signature on later comment pages

**Priority: Medium · Confidence: High in the unpaginated path and integrated reproduction · Type: conditional upstream automation defect**

The same [selected action revision](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L20) [lists issue comments once without `page`, `per_page` or pagination](https://github.com/contributor-assistant/github-action/blob/ca4a40a7d1004f18d9960b404b97e5f30a505a08/src/pullrequest/signatureComment.ts#L11), then [looks for signatures only in those returned comments](https://github.com/contributor-assistant/github-action/blob/ca4a40a7d1004f18d9960b404b97e5f30a505a08/src/pullrequest/signatureComment.ts#L19). The GitHub REST list-comments default is 30 items. The repository's [exact signing-comment event gate](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L19) does not solve this: the action rereads the old first page rather than consuming the triggering comment's body.

An integrated fixture of the actual action modules placed an unsigned contributor's valid signature at comment 30 and then 31, with the same contributor and ledger otherwise unchanged. At 30 the action updated the ledger and succeeded; at 31 it did not record the signature and failed the check. The stub explicitly models the documented default API page; this is not an observed live rejected signature. The SDK path has no automatic-pagination call. Posting another signature or `recheck` appends to the thread but does not move that signature into the first page.

**Recommendation:** use an audited revision that paginates comments or securely consumes the triggering signature event and resolves its author/PR. Check for the existing bot comment across pages too, to avoid duplicate prompting. Add boundary tests for signature positions 30/31 and later pages, and retest required-check recovery in a controlled repository. Keep this operational defect separate from any legal conclusion about whether a person has agreed to terms.

O5.5 Response: as C1: no fixed upstream revision exists; pinned by SHA; PRs with over 30 comments are unlikely for now.

## Plausible operational risks

These are supported exposure or design concerns, not demonstrated compromises. The ratings describe the plausible consequence under the stated condition.

### R1 — Public model invocation has no repository-level consumption control

**Priority: Medium · Confidence: High in exposure; cost/service impact depends on service settings**

Any [non-bot discussion author whose text contains `@claude`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L19) can invoke the secret-backed [Opus call with web tools and up to 20 turns](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L54). There is a [15-minute timeout](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L23), but no author association gate, per-author quota or global spend/concurrency budget in the repository. [Concurrency is scoped to one discussion](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L13), so activity across discussions is not globally serialised. Public invocation is intentional in the [README](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/README.md?plain=1#L135); repeated public invocations expose aggregate usage and quota to other users, within whatever service/account limits apply. No privileged shell access was demonstrated.

**Recommendation:** explicitly choose a public-access budget and enforce a global/per-author limit or maintainer approval for new/untrusted participants. Bound input size and model usage, add a circuit breaker and monitor failures/consumption. Verify external subscription/account limits rather than assuming repository code supplies them. Retain the tool allowlist and bot-loop filter.

O5.5 Response: Martin's decision. Public invocation is intentional (README); whether to limit it to people with a repository association is open. A global concurrency group was not added, because GitHub keeps only one pending run per group and would drop answers.

### R2 — Automatic blinking lasts beyond five seconds without a page control

**Priority: Medium · Confidence: High in behaviour; accessibility impact requires user assessment**

All [eight page logos are animated](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L290). The engine schedules [six automatic blinks with repeated delays](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L253), spanning well beyond five seconds alongside reading content, and exposes no page pause/stop/hide control. The [initial reduced-motion preference](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L238) correctly disables the animation, which is a useful mitigation. The engine samples that preference only when mounting: a real Chromium media-preference change from normal to reduced motion left 16 queued draw/blink callbacks active and subsequent frames still changed the artwork. The finite animation eventually stops; the test does not establish perpetual motion.

**Recommendation:** end all automatic movement within five seconds, make blinking opt-in, or provide a keyboard-accessible pause control. Consider preference changes while the page is open. WCAG 2.2.2's pause/stop/hide requirement should be assessed for this intermittent animation; the report does not claim a complete conformance determination from source inspection alone. The copy's intended audience includes people with visual or cognitive difficulties, making distraction worth addressing.

O5.5 Fixed: two blinks, all movement over within about 5 s; switching to reduced motion while the page is open stops it.

### R3 — Automated public safety answers lack some of the project context

**Priority: Medium · Confidence: High in omitted input; answer-quality impact not live-tested**

The bot is instructed to answer about [hardware, radio, standards and regulation using its own expertise and web research](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/claude/discussion-prompt.md?plain=1#L7). Its [document list](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L60) excludes `docs/app-spec.md`, where important iPhone SMS, alert-entitlement and relay limitations are recorded. It posts the generated answer [without a human review step](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L73). The prompt's public-thread trust boundary, instruction to distinguish suggestions from decisions, prohibition on promises, restricted web-only tools and credential-pattern filter are meaningful safeguards. They do not guarantee factual accuracy or resistance to every prompt injection.

**Recommendation:** include the app specification and a concise explicit list of unresolved safety/platform limitations in the context; keep a source revision for reproducible answers. Decide which safety/regulatory questions require human review or a referral rather than a generated recommendation, and tell readers when an answer is unreviewed. Test adversarial thread text, contradictory sources and missing context with harmless fixtures. No arbitrary shell execution, runner-file access or token exfiltration was demonstrated, and none is asserted here.

O5.5 Fixed: `docs/app-spec.md` is in the bot's document list. Human review of safety answers is Martin's decision.

### R4 — CLA automation shares a privileged dependency and the production branch

**Priority: Medium · Confidence: High in configuration; protection/deployment effects unverified**

The [CLA workflow grants write permissions](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L8), runs on `pull_request_target`, and uses a [mutable version tag](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L20). It does not check out untrusted pull-request code, so `pull_request_target` alone is not a demonstrated exploit. The action is nevertheless a third-party execution boundary with a write token. It also [stores signatures on `main`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L24), which the [README identifies as the production deployment branch](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/README.md?plain=1#L127). Branch protections may prevent those direct writes; allowing them may cause administrative signature commits to enter the deployment branch. Remote branch protections, Workers Builds settings and deployment triggers were not inspected.

**Recommendation:** pin a reviewed action SHA, verify every required permission, and use a dedicated signature-storage branch or repository with a narrowly scoped write route. Verify first-use and signing against actual branch-protection rules without weakening production protections. Make CLA document/version changes an explicit reviewed process: [the signing URL follows mutable `main/CLA.md`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L25), although the ledger path is versioned. This is a governance/control recommendation, not a legal conclusion about existing signatures.

O5.5 Response: action pinned by SHA. Moving signatures off `main` to a dedicated branch is Martin's decision.

### R5 — Separate footnote links from disclosure controls

**Priority: Medium · Confidence: High in the automated finding; assistive-technology impact unverified**

The Neighbours and Communities [summaries contain focusable footnote links](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L153), [including the second affected summary](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L157). Axe-core 4.10.3 flagged these two controls with its serious `nested-interactive` rule in all three audited page scenarios. This is a reproducible tool finding associated with WCAG 4.1.2, not proof that every browser/screen reader loses the link or that an anchor inside a summary is inherently invalid HTML. Chromium's accessibility tree exposed both links and disclosures, and keyboard activation worked; no screen reader was run.

**Recommendation:** move the footnote links outside the focusable summaries, or use noninteractive footnote text in a summary and a separate adjacent link. Verify announcement, focus and operation with representative assistive technology. Axe's additional `landmark-one-main` and `region` results are best-practice findings, not separately asserted WCAG failures. Its eight incomplete hero contrast nodes require manual evaluation; the readiness-notice contrast in F4 comes from the separate colour calculation, not a claimed axe pass or detection.

O5.5 Fixed: summaries hold only a heading and phrasing content; the footnote stars inside them are no longer links. Not run through axe or a screen reader.

## Design gates before implementation or reliance-based trials

The following omissions are appropriate work for the design phase. They should become explicit requirements and tests; they are not findings that nonexistent firmware or apps already fail them.

| Gate | Evidence and unresolved consequence | Concrete next step |
|---|---|---|
| Durable offline escalation and responder alerting | [Selection and timed escalation are assigned to “the app”](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L26); [offline Bluetooth background alerts are promised](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L63), while [core functions cannot depend on a phone/app](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/AGENTS.md?plain=1#L48). It is unclear who owns the outstanding request if a caller has only the box or a phone dies after the initial transmission. | Define the durable authority/failover for each deployment configuration, who holds the rota and timers offline, and what continues after reboot or loss of a device. Prove the selected hardware/phone combination before promising unattended alerts. Core Bluetooth background operation is possible; this review does not assert it is categorically impossible or requires an unspecified special entitlement. |
| Notification permission and lifecycle limits | [Critical Alerts requires an entitlement grant](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L89); [Time Sensitive alerts are said to get through Focus](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L92). Users can disable Time Sensitive notifications or permit Focus to suppress them, and a network or OS state can still prevent delivery. | Describe the entitlement and user-setting preconditions, detect/report degraded capability where possible, and establish a supported responder setup. Test locked, background, terminated, rebooted, Bluetooth-disconnected and notification-disabled states on real iPhones/watches, plus silent/Focus settings and no internet. Do not treat push acceptance as a guaranteed alert. |
| Authenticated request and acknowledgement protocol | The spec introduces [unit, colour and message identifiers](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L41), [cross-route deduplication](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L50) and [acknowledgement](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L54), but not an authenticated envelope, identifier persistence/scope, replay rules or authorisation for an acknowledgement. [Provisioning and lost-phone removal are already explicit open questions](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L105). | Define authorised responder identity, per-request binding, unique persistent IDs, idempotent merging, replay/late-message handling and revocation/key rotation for offline members. Define green/repeated-press/manual-resolution behaviour without silently treating green or an old acknowledgement as automatic closure. Test a delayed acknowledgement for a previous request after a reboot. No forgery or automatic closure is established by the current documents. |
| SMS confidentiality and correlated failure routes | [SMS is a planned route](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L60), but [follow-up encryption is described explicitly for internet and mesh](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L45), not an SMS payload/encoding. [The site says typed content is readable only by responders](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L225). Internet and SMS may also share one handset, SIM, mast, power source or OS. | Specify SMS recipients, payload, composer visibility, encryption if used, receipts and duplicates. Prohibit personal follow-ups over ordinary plaintext SMS unless an explicit end-to-end mechanism is designed. Describe routes as alternatives with correlated failures, not independent guarantees. Define what [“another route worked”](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L53) means before suppressing mesh follow-ups. There is no evidence that plaintext personal SMS is currently implemented or intentionally selected. |
| Radio capacity, priority and hardware feasibility | [IR 2030 limits are mandatory](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/AGENTS.md?plain=1#L56); [red/amber use all automatic routes and follow-ups share constrained mesh airtime](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L50). [Battery reports and outage aggregation](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/README.md?plain=1#L101) could coincide across an entire group. [Standard companion firmware is assumed](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L11), while [required acknowledgement/Wi-Fi behaviour remains open](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/design-decisions.md?plain=1#L29). | Fix the regional sub-band, radio settings, packet/retry budget, queue priorities and congestion behaviour; prevent battery/status/follow-up traffic from starving red calls or their acknowledgements. Model a group-wide outage, multiple simultaneous red requests and weak links, then measure range, duty cycle, buttons, sound, battery reserve and mains sensing on the actual boards/enclosures. Do not infer finished-unit conformity from a board specification or a green first-aid mark. |
| Relay capacity, privacy and operations | The [free relay must detect approaching/exhausted allowance](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L79), potentially while the same relay is unavailable. [Relays use external push providers](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L69). [Consent is planned](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L16), but storage lifetime, device backup exposure, push metadata, operational access, abuse handling and relay recovery are not defined. | Specify how capacity is measured and warnings/failure states are delivered if the allowance is exhausted; distinguish aggregate account limits from per-group budgets. Define retention/deletion, mappings held on phones, provider-visible metadata, recovery/monitoring and support responsibilities. A stable unit number is pseudonymous rather than a guarantee of anonymity; qualify [“a stranger … cannot tell who”](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L224) to the documented threat model. The second relay improves provider resilience but does not remove push/handset common dependencies. |

## Lower-priority recommendations and governance observations

- **HTML semantics:** the four summaries at [line 153](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L153), [line 155](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L155), [line 157](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L157) and [line 159](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L159) contain an `h3`, a `p` and a `span`. A summary's permitted content is phrasing content or a single heading; the paragraph-plus-heading structure needs cleanup. Use a valid summary label/heading and place descriptive block content outside it. Chromium accepted these controls and Enter/Tab checks passed; no screen-reader failure is claimed. No formal HTML validator was installed or run.
- **Reproducible asset exports:** [the generator docstring points to PNG-rendering instructions](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L12), but [the brand README](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/README.md?plain=1#L7) does not contain them. Document the exact rasterisation command, dimensions, colour/background handling and tool version for `site/apple-touch-icon.png` and `site/og.png`, and the favicon export. The favicon itself matches the generator function's expected transparent-cross output. Consider one shared source/update process for the duplicated static marks and the [site's extra cross construction](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L283).
- **Copied engine provenance:** [the JavaScript header still says “Events&I” and points to `../../LICENSE`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L1), although this file is under `site/`. Record the shared engine's source revision and correct the project/path wording when next updating it. This is a maintenance detail, not a finding that the repository lacks a licence.
- **Testing scope:** [the contribution rule covers every user-facing behaviour change](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CONTRIBUTING.md?plain=1#L9), while the [test-location table only names firmware/hardware](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CONTRIBUTING.md?plain=1#L48). Add a small documented website/workflow verification path so contributors know where browser, payload and automation fixtures belong. The [empty manual test file](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/tests/MANUAL-TESTS.md?plain=1#L6) honestly reflects the lack of a first hardware prototype and is not itself a defect.
- **Licence and governance:** a full AGPL-3.0 text, contributor guidance, CLA v1.0 and contributor list are present and broadly consistent about retaining copyright and permitting additional relicensing. The [CLA describes its AI-assisted drafting](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CLA.md?plain=1#L28) and [entity representations](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CLA.md?plain=1#L89). No conclusion about legal enforceability or App Store distribution rights was reached. Verify rights/provenance for actual third-party firmware/app dependencies when selected, and obtain appropriate human/legal review before depending on licensing or certification claims. [Standards/conformity gaps are explicitly acknowledged](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/design-decisions.md?plain=1#L34); missing certification is not misreported as an undisclosed current feature.

## Checks actually run

These are fresh review checks, not a newly added maintained test suite. Temporary fixture/browser files are outside the repository. A pass covers the described case only.

| Check / command | Result and scope |
|---|---|
| `git rev-parse HEAD`; `git status --short`; `git ls-files` | Exact target commit, clean initial tree, 30 tracked files. Original-file hashes recorded separately for the final integrity check. |
| `node --check site/andeye-eye.js` | Passed JavaScript syntax. |
| Python `ast.parse(Path('assets/brand/gen_mark.py').read_text())` | Passed without generating bytecode in the checkout. |
| Python `json.loads` of `wrangler.jsonc` | Passed; the current JSONC file contains no comments and is valid JSON. This is not Cloudflare schema/deployment validation. |
| PyYAML `BaseLoader` parse of both workflow YAML files; `bash -n` on each extracted `run` block | Both YAML files and all three Discussions shell blocks passed syntax parsing. This does not validate GitHub event/service semantics or execute the workflows. |
| Generator copied alone to a fresh `/tmp/helpandeye-generated-*` directory; `python3` run there; `cmp` each output | Seven outputs, all byte-identical to tracked counterparts. WhatsApp SVG not emitted. Favicon compared with `mark(None, GREEN, 'f')` and matched. |
| UTF-8/CR/trailing-space/final-newline scan of all tracked text; ElementTree parse of each SVG | All 28 text files decode as UTF-8; all nine SVGs parse. No CR or trailing-space diagnostics. Only `icon-whatsapp.svg` lacks a final newline, a cosmetic observation. |
| `file site/*.png`; ImageMagick `identify -verbose`; image viewers | Both PNGs decode and were visually inspected. Touch icon: 180×180, 8-bit RGBA, fully opaque. Open Graph: 1200×630, 16-bit RGB. Metadata dimensions match the site; no apparent corrupt artwork. |
| Python inline Markdown relative-target scan; HTML root-relative asset check | No missing targets in the limited inline-link scan; `/favicon.svg`, `/apple-touch-icon.png` and `/andeye-eye.js` exist. Not a complete Markdown parser/anchor/external-link check. |
| `node /tmp/helpandeye-review.js` using installed Playwright and `/usr/bin/chromium` | Browser route fixture supplied repository files at `http://site.test/`: 1280×800 normal motion/JS on, 320×800 reduced motion/JS on, 320×800 reduced motion/JS off. No page errors; eight logos; all fragment targets resolved; Enter opens/closes disclosure; Tab reaches nested footnote; static mark present without JS. Screenshots inspected. |
| `node /tmp/helpandeye-overflow.js` | At 320 px no real DOM element extended beyond the viewport. The 352 px scroll width comes from the decorative `120vw` pseudo-element glow, clipped by the body. No content-clipping defect was inferred from scroll width alone. |
| Computed colour styles plus sRGB contrast calculation | Primary normal 3.68:1, hover 2.87:1, faint text 4.00:1; F4. Green on card approximately 4.81:1. |
| Self-contained Python `ThreadingHTTPServer` with ephemeral loopback port; HTTP reads compared to file bytes | `/`, `/andeye-eye.js`, `/favicon.svg`, `/apple-touch-icon.png`, `/og.png`: all 200 with expected HTML/JS/SVG/PNG content types, 28,437 / 14,764 / 1,075 / 3,918 / 26,349 bytes respectively, byte-identical to source. Server stopped after the check. This is ordinary static serving, not Cloudflare headers or Worker routing. |
| `python3 /tmp/helpandeye-security-review/check_workflows.py`; independent thread-formatting/reply-parent `jq` fixtures | Syntax/assets checks passed; correct trigger placement for included comments; trigger omitted and reply parent empty at the 101st top-level comment/reply; F5. Public shell metacharacters remained literal and did not execute. No live comment posted. |
| `node /tmp/helpandeye-security-review/cla-pagination.js` | Actual upstream bundled contributor-enumeration module returned after one GraphQL call despite 101 reported commits and `hasNextPage:true`; C1. Rerun independently by coordinator. |
| `node /tmp/helpandeye-cla-pagination-challenge.js` | Independent integration fixture using actual contributor/comment-decision/CLA-setup modules: unsigned author at commit 101 incorrectly reaches success; author at commit 100 causes signature request and failure. Rerun independently by coordinator. |
| `node /tmp/helpandeye-security-review/cla-bootstrap.js` | Numeric/string experiment ran but omitted HTTP-error normalization; rejected as insufficient evidence for a bootstrap defect, as explained under C1. |
| Verified-HTTPS reads of upstream CLA v2.6.1 archive/source and configured raw `main` ledger URL | Upstream version inspected; raw ledger URL returned HTTP 404. Initial restricted-network requests failed at the configured proxy; permitted escalated reads succeeded without disabling certificate verification. No authenticated GitHub workflow run was made. |
| `git diff --check`; `git diff --no-index --check /dev/null CodexReview.md` | Tracked-source check passed with exit 0. The new-file check emitted no whitespace diagnostics; exit 1 indicates the report differs from `/dev/null`, as expected for an additional file. |

### Minimal repeatable examples

Run the following from the repository root; generated outputs remain outside it:

```sh
set -eu
node --check site/andeye-eye.js
task_asset_dir=$(mktemp -d /tmp/helpandeye-generated-XXXXXX)
cp assets/brand/gen_mark.py "$task_asset_dir/"
python3 "$task_asset_dir/gen_mark.py"
for generated in "$task_asset_dir"/svg/*.svg; do
  cmp "$generated" "assets/brand/svg/${generated##*/}"
done
git diff --check
```

The following independent calculation reproduces the colour ratios without browser or network dependencies:

```python
def luminance(hex_colour):
    rgb = [int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
    return sum(c * weight for c, weight in zip(linear, (0.2126, 0.7152, 0.0722)))

for foreground, background in [
    ('#ffffff', '#009a44'), ('#ffffff', '#00b04e'), ('#6a7382', '#0c0f16')
]:
    low, high = sorted((luminance(foreground), luminance(background)))
    print(foreground, background, round((high + 0.05) / (low + 0.05), 2))
```

To reproduce the browser scope, serve or route the unchanged `site/` directory, launch Playwright Chromium at 1280×800 with normal motion and at 320×800 with reduced motion, then repeat with JavaScript disabled. Capture `pageerror`, count eight `svg.eye` elements, check every `a[href^="#"]` target, focus the first summary and press Enter twice, then Tab to its footnote. Measure each real element's bounding rectangle before calling document scroll width an overflow failure. The recorded browser scripts used local route fulfilment and no external application services.

For F5, construct API-shaped fixtures with `comments.nodes` and `replies.nodes`, retain only the first 100, and apply the exact `jq` blocks at [lines 42](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L42) and [50](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L50) with `COMMENT_ID` set first to an included node and then to node 101. The latter yields no “this is the message” marker and an empty `reply_to`. For C1, execute the fixed-version bundle's contributor-enumeration module with a stub GraphQL response containing 100 edges, `totalCount:101` and `pageInfo.hasNextPage:true`; assert that it fails to ask for the next page. No GitHub credentials or writes are necessary for either fixture.

## Bounded behavioural verification

The follow-up distinguishes **reading every file**, **executing every explicit function**, **hitting an instrumentation tool's measured control-flow ranges**, and **asserting intended behaviour**. They are different claims. No repository-wide “all behaviour verified” percentage is justified. There are 38 explicit first-party function units: 26 function literals in the eye engine, three in the page's inline script, and nine Python function definitions. All were exercised. Tool-generated script/module wrappers and Python generator-expression code objects are identified separately rather than silently changing that denominator.

The temporary harnesses are review artifacts outside the checkout, not committed regression tests. They use independent geometry, DOM/pixel observations, documented API conditions and failure controls; they do not merely copy the implementation's arithmetic. Mutation controls demonstrate sensitivity to selected incorrect implementations, not proof that every possible defect would be caught.

Instrumentation measures normal control flow under the tool's definition. Even 100% measured statement/branch coverage does not enumerate every implicit exception edge, input value, concurrency/interleaving, filesystem interruption, renderer, external response or mistaken oracle. The workflow/CLA case ledgers have zero unrun cases **within their implemented finite suites**; that does not mean zero unverified requirements. The excluded environmental and design boundaries remain open and are listed below.

### Measured results and failed intended properties

| Subject | Result | Exact meaning and limits |
|---|---|---|
| Eye engine | 74/74 finite contract cases; 2,182 assertion calls; 14/14 selected mutants rejected | Separate diagnostic properties include **two failures**: late-mount draw/blink sequencing (F8) and a synthetic first-frame timestamp of zero. Early-mount and blink-disabled diagnostic controls pass. These failures are not hidden inside the passing-case total. |
| Engine V8 coverage | 27/27 reported functions, including the script wrapper; 106/106 emitted execution ranges, of which 79/79 are nested ranges; no zero-count ranges | The static source has 26 function literals. This is runtime V8 range/function coverage, **not** source branch coverage, MC/DC, a path denominator, or all logical outcomes. The valid-public-API-unreachable parent-false outcome remains unexercised despite the positive range metric. |
| Engine static-AST coverage | Istanbul: **172/172 statements, 137/137 tool-reported lines, 26/26 functions, 107/108 branches (99.07%)** | Independent temporary-source instrumentation with `istanbul-lib-instrument` 6.0.3 and `istanbul-lib-coverage` 3.2.2, using the same 74 passing contracts/2,182 assertions. The sole uncovered branch is the implicit false arm of `if (parent)` at line 109. It remains included in the denominator; no private helper/invalid input was introduced to manufacture 100%. |
| Actual-page slow-script reproduction | Two scenarios, 84 reproduction/control assertions | Exact site/engine bytes, native rAF, immediate versus 4,800 ms delayed local script response. All eight late mounts reveal the full mark within about 12–56 ms, then revert to incomplete drawing around 380–397 ms; immediate response does not prematurely reveal. Assertions demonstrate the bug and controls, not a repaired application. |
| Python generator | Seven case groups; 267 successful assertion calls plus three expected mutant-assertion failures; all nine functions | Includes 24 main icon configurations: three appearances × two platforms × four positive canvas sizes, plus defaults/boundaries and CLI cases. These are not 267 independent behaviours. |
| Generator coverage.py 7.6.1 | **79/79 measured statements and 22/22 measured branches**, zero missing/excluded lines, missing branches or partial branches | Independently collected against a byte-identical `/tmp` copy, including import and actual CLI entry. Same-line conditional expressions at lines 116/117 are not branches in this tool's denominator; their alternatives are covered by the icon matrix. The earlier 95/95 bytecode line-start / 104 observed-arc measurement is a different metric, not substituted for this one. |
| Page integration | 48/49 assertions pass; one failed intended property is F7 | Five baseline viewports, mounts, disclosure/anchor/Tab interaction, initial preferences and fallback paths. The strengthened normal-mount oracle requires generated `eye...` clipping IDs; no-JS/missing-engine static `ape...` fallbacks are explicitly rejected by that oracle and checked separately. One in-memory wrong-cross-colour mutant is caught. |
| Inline JavaScript | Three source function literals plus the script wrapper executed; both outcomes of its one explicit `if` exercised | Normal: wrapper/IIFE once, SVG callback eight times, point-map callback 96 times. Missing-engine case executes the early return at line 288. Normal-only uncovered offsets 321–328 and missing-engine unexecuted remainder 328–1043 are complementary, not discarded. No engine or browser coverage is inferred from these inline counts. |
| Inline static-AST coverage | Istanbul: **16/16 statements, 13/13 tool-reported lines, 3/3 functions, 2/2 branches** | Independent normal/missing-engine contexts preserve eight generated/static marks respectively. Tool lines are instrumenter-defined executable locations, not a claim about every physical HTML line. |
| Discussions workflow | 83/83 named scenarios; 238 successful check calls plus five expected mutant-assertion failures | 59 actual-shell scenarios, 16 custom expression-model cases, two local runner-gating models, one configuration case and five mutants. The actual YAML shell snippets run with `bash -e`, real `jq`, and fake `gh`/`npm`/`claude`; modeled GitHub conditions are not execution of GitHub's expression engine. |
| Selected CLA dependency logic | 89/89 scenarios; 217 successful check calls plus six expected mutant-assertion failures | 55 behaviour, three defect-demonstration, three edge-behaviour, six mutation, two negative-control, four stub-error-shape, one unconfigured-event and 15 unconfigured-input scenarios. APIs, tokens, Actions SDK/context and writes are stubbed. Success of defect-demonstration assertions means the defect was reproduced, not that the gate is correct. |
| Selected upstream V8 coverage | 199/225 reported functions and 385/446 ranges across 12 selected modules | Partial coverage, including transpilation helpers; 26 reported functions and 61 ranges remain unexecuted. The remainder of the upstream bundle, network/SDK dependencies and source-only code are excluded. This is not coverage of the entire dependency or first-party YAML. |
| Automated accessibility | Axe-core 4.10.3, three scenarios | Desktop collapsed/expanded: four violation rule IDs, 35 passing and 53 inapplicable rules, plus eight incomplete contrast nodes. Large-font mobile: three violation rule IDs, 35 passing and 53 inapplicable rules, plus the same incomplete nodes. Contrast and nested-interactive are distinguished from best-practice landmark/region results; no overall conformance percentage is claimed. |
| Local Cloudflare runtime | Wrangler 4.154.0; 20/20 HTTP path cases across default and `dev` | Five 200 asset responses with exact bytes/types, `/index.html` 307 to `/`, and four 404 paths per environment. Byte-identical external copies; servers stopped and ports closed. No configuration warnings; a cancelled `Request.cf` fetch used a placeholder. Production cloud behaviour is outside this result. |

The parent reviewer independently reran the engine suite/mutations and selected CLA controls, inspected the coverage/oracles, and collected the Python and Istanbul coverage results. The independent challenger reran the workflow/CLA suites and browser controls, and rejected a weak initial static-logo mount oracle and the earlier incomplete CLA-bootstrap hypothesis. Those corrections are reflected in the final results.

### Complete explicit function inventory

For the engine, every listed literal ran under actual Chromium; invocation counts and all range offsets/counts are retained in `coverage-summary.json`. These links map the inventory to source rather than implying that a multi-line function's every possible input was tested.

| Engine function unit | Definition |
|---|---|
| Module IIFE | [line 17](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L17) |
| `P` | [line 20](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L20) |
| `trailing` and its interpolation helper `m` | [line 38](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L38), [line 39](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L39) |
| `closedPose` | [line 48](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L48) |
| `lerp` | [line 55](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L55) |
| `cubics` and `OPEN.map` callback | [line 56](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L56), [line 58](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L58) |
| `seg` | [line 65](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L65) |
| `segmentPaths` and its map callback | [line 75](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L75), [line 76](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L76) |
| `aperturePath` | [line 82](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L82) |
| `pointOn` | [line 86](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L86) |
| `irisGeometry` | [line 94](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L94) |
| `el` | [line 106](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L106) |
| `andeyeEye` | [line 113](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L113) |
| `person` glyph helper | [line 161](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L161) |
| Outline creation map callback | [line 196](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L196) |
| `setPose` | [line 203](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L203) |
| Path-length map and sum-reduce callbacks | [line 216](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L216), [line 217](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L217) |
| `setWink` | [line 236](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L236) |
| `drawFrame` | [line 244](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L244) |
| `smooth` | [line 259](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L259) |
| Blink `frame` | [line 260](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L260) |
| `andeyeEye.tune` | [line 283](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L283) |

The page's three inline literals are [its IIFE](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L287), [per-SVG callback](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L290), and [point-map callback](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L297). V8 adds one script wrapper for each JavaScript source. The generator's nine definitions are [`P`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L19), [`_seg`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L30), [`_path`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L34), [`_aperture`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L37), [`_point_on`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L42), [`cross`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L63), [`mark_body`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L73), [`mark`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L99), and [`icon`](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L110). Its module/CLI entry and generator expressions also execute; they are not additional named API functions.

### Source-mapped engine decision and oracle matrix

| Source decision | Exercised outcomes / independent assertions |
|---|---|
| [Extrema loop](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L97) | Iterations and exit; radius compared to analytic extrema of the separate committed brand cubics. |
| [Attribute enumeration and parent](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L108) | Empty/nonempty attributes and all actual parented calls. **Parent false at line 109 is unreachable through valid exported calls and remains untested.** Private helpers were not exposed merely to fill the metric. |
| [Options/default fallbacks](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L114) | Omitted/null options, omitted/empty and custom colour, omitted/empty/none/fill/stroke iris, absent/null/empty and all glyphs. Unknown iris/glyph are characterized fallbacks, not advertised supported features. |
| [Iris construction](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L123) | None omits iris/defs/clip; fill/stroke create them; stroke outside radius aligns with filled radius, hollow centre verified in pixels. |
| [Glyph selection](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L140) | Clock, tick, people, calendar and code, no glyph and unknown fallthrough; both iris modes and supplied/default background. Topology, direction, shapes and ink checked rather than only node counts. |
| [People ring](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L162) | Rear people without ring, front with ring; front size and separating outline checked. |
| [Code inset/ink](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L184) | Filled/stroke modes and custom/default background; right-facing open chevron. Exact numeric inset is characterized rather than invented as a product requirement. |
| [Iris opacity](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L204) | Iris absent/present; optional, negative/zero/fractional/full/above-full draw values at three wink poses; partial draw has no iris pixels. |
| [Full/incomplete drawing](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L209) | Null/undefined short-circuit, full/above-full, zero/intermediate; stale dash/offset cleared and visibility restored. |
| [Draw mask and arc calculation](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L215) | Negative clamped to zero; forward/backward updates; independent total visible arc length and contiguous reveal order. All four map/reduce/segment iterations and loop exits execute. |
| [Segment boundary](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L220) | Just below/at/above every cumulative-length boundary; full/partial/hidden cases, at most one partial segment and positive residual gap. |
| [Clip update](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L234) | No-iris bypass and iris update; instance isolation, clip references and raster containment. |
| [Motion capability/preference](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L238) | `matchMedia` absent, present false and present true; initial reduced motion schedules neither automatic animation. Live preference change is separately tested and remains R2. |
| [Draw-on scheduling](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L242) | Omitted/true with normal/reduced motion, combined and blink-disabled modes; first/subsequent callbacks, 1,200 ms completion and skipped-frame completion. Timestamp-zero and late-mount failures remain separate diagnostics. |
| [Blink policy](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L253) | Default/true, false, reduced motion; idle/active/return-to-idle; before/at/after deadlines using three random-delay values. |
| [Blink phases](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L265) | Closing 0–130 ms, hold to 190, opening to 360, boundary/midpoint/skipped frames; nonlinear easing and endpoint geometry asserted. |
| [Blink terminal count](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L270) | First five completions reschedule, sixth stops; minimum-delay sequence lasts 16,960 ms. No claim that the finite sequence satisfies every user's motion needs. |
| [Tune guards](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L284) | Missing/null/false object, absent/wrong-type properties, numeric zero/one for lift/smooth; lazy change across instances, lower/upper lid isolation, unchanged open pose and restoration. Arbitrary tuning combinations are not promised the default no-inversion property. |

Additional geometry checks sample 21 wink values against independent de Casteljau/analytic calculations: fixed flourish/corners, tail on its original cubic, default lid ordering, closed endpoint precision, and actual pixel clipping. The raster has 6,555 interior iris-colour pixels open, zero closed and zero strong interior-colour pixels outside the aperture in the tested configurations. Sixty-four seeded IDs are distinct and resolve locally; this is not a proof against all random collisions. Unsupported NaN/Infinity, arbitrary primitives/malformed SVG, external mutation of private arrays and all continuous inputs are outside the finite contract matrix.

### Generator decisions, properties and exceptions

The suite exercises the background-None decisions [at 77](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L77) and [85](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L85), icon background/platform decisions [at 124](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L124) and [125](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L125), module import/CLI [at 135](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L135), and body/exit of the loops [at 94](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L94), [141](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L141) and [143](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L143). Both choices of the same-line colour/platform expressions [at 116](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L116) and [117](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L117) are covered independently of coverage.py's line-arc denominator.

Assertions check fixed translation/formatting, cubic endpoints/midpoint/control-hull bounds, a 12-vertex equal-sided cross with five-square area/perimeter and centring, valid XML and matching clip/mask IDs, transparent knockout versus filled iris, full-bleed versus inset rounded plates, mark width and vertical/horizontal centring. Supported appearances/platforms run at 64/512/1024/2048 canvas sizes, with defaults and a positive size-one boundary. Invalid appearance raises `KeyError`; zero canvas, unknown platform and cubic extrapolation are explicitly unsupported-input observations, not product defects. Fresh output, deterministic overwrite with unrelated-file retention, and an output-directory/file conflict are tested. Permission races, full disk, interrupted/partial writes and every OS renderer are not.

### First-party workflow decision/outcome matrix

| Source / boundary | What local execution or modeling establishes |
|---|---|
| [Discussions events/job condition](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L7) | Model cases include body/comment mentions, bot exclusion, case-insensitive mention matching, nonmentions and substring matches. These use a custom expression model plus source inspection, not the hosted GitHub evaluator. Created-only triggers, scheduling and per-discussion concurrency remain platform configuration evidence. |
| [Gather shell block](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L37) | Actual Bash/`jq` for discussion/top-level/reply targets, deleted/null authors, first-page boundaries, malformed/null/API-error responses and literal metacharacters. Command/output failures stop under the local `bash -e` model; F5 demonstrates omitted trigger/parent. |
| [Prompt/CLI block](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L58) | Actual file concatenation and CLI argument/input capture, pinned npm version and web-only flags; stub failures for npm/CLI, malformed/empty output, missing/null/type variants, whitespace and lengths 0/1/5,999/6,000. Live model/schema enforcement is not tested. |
| [Reply-length predicate](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L71) | String boundaries reject empty/6,000 and accept nonempty/5,999. Nonconforming stub outputs such as numeric `42` or `is_error:true` with a valid reply and exit 0 can pass the local check; this characterizes delegated CLI-schema/status assumptions, not a demonstrated real CLI response defect. |
| [Credential-pattern filter](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L80) | Each pattern alternative and 19/20-character boundary tested with positive/negative controls; matching output is blocked, ordinary text retained. This heuristic is not a complete credential detector and no real secret is used. |
| [Posting branch](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L83) | Actual argument construction for root/reply, multiline/Unicode/metacharacter data and API failure; captured GraphQL variables preserve data literally. A local Ask→Post success gate prevents posting after a failed Ask; that model does not prove hosted-runner semantics. |
| [CLA trigger/input boundary](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L3) | Source/model cases for target PR events and exact signing/recheck comments; actual selected dependency logic tested separately below. Required status checks, token scopes in practice and branch protection remain unverified. |


<details>
<summary>Complete 25-element first-party workflow decision inventory</summary>

This inventories every declared event/condition and the shell decisions, loops and output boundaries identified in the two workflows. Rows explicitly mark actual shell execution versus platform modeling or inspection. It is a finite outcome inventory, not a language branch percentage.

| Element | Source | Outcomes covered | Boundary |
|---|---|---|---|
| YAML events | [claude-discussions.yml:7](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L7); [cla.yml:2](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L2) | Configured discussion/comment created; PR opened/closed/synchronize; issue_comment created | Static configuration only; event delivery/edit/deletion/fork policy not executed |
| Discussion sender gate | [claude-discussions.yml:19](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L19) | User allowed / Bot denied | Local expression parser, not GitHub engine |
| Discussion message selection | [claude-discussions.yml:21](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L21) | Discussion body / comment body / empty-body fallback | Local expression parser |
| Mention search | [claude-discussions.yml:21](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L21) | Absent / present / casefold / quoted / longer handle | Local expression parser; substring matching is intended by actual contains expression |
| CLA step condition | [cla.yml:19](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L19) | pull_request_target / exact signing text / recheck / casefold / whitespace / other | Local expression parser |
| Concurrency, limits, permissions | [claude-discussions.yml:13](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L13); [cla.yml:8](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L8) | Per-discussion grouping, no running cancellation,15min; declared token permissions | Read and asserted only; queue capacity, event ordering, cancellation and effective token grants not executed |
| Shell syntax and default | [claude-discussions.yml:36](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L36),57,78 | All actual run snippets parsed; local bash -e used | No explicit shell in YAML; local host differs from ubuntu-latest |
| Gather API command | [claude-discussions.yml:37](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L37) | Quoted owner/name/number; first100 limits; exit failure | gh API transport and GraphQL schema stubbed |
| Gather JSON shape | [claude-discussions.yml:42](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L42) | Valid / malformed / null discussion/comments/replies / errors payload | No live GitHub malformed response claim |
| Gather discussion marker | [claude-discussions.yml:43](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L43) | Empty COMMENT_ID marks initial discussion; nonempty marks matching comment/reply | Actual jq |
| Gather author fallback | [claude-discussions.yml:43](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L43) | Known / deleted author for discussion/comment/reply | Actual jq |
| Gather nested iteration | [claude-discussions.yml:44](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L44) | Zero / one / multiple /100 comments and replies | Actual jq over fixture API result |
| Gather parent resolution | [claude-discussions.yml:50](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L50) | Top-comment ID / nested reply parent / missing trigger | Actual jq; missing trigger silently becomes root reply |
| Gather output/text quoting | [claude-discussions.yml:42-52](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L42) | Quotes,command substitution,newlines remain data; outputs contain IDs | Only text fields attacker controlled in fixture; IDs use valid-format examples |
| Prompt dependencies | [claude-discussions.yml:58-65](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L58) | npm succeeds/fails; actual project files concatenated; missing file stops | npm stub does not install anything |
| Claude command controls | [claude-discussions.yml:67-69](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L67) | Pinned package/model,WebSearch/WebFetch,strictMCP,20turns,schema | Arguments verified; real CLI tool/schema/provider enforcement not tested |
| Claude process/JSON failure | [claude-discussions.yml:70-71](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L70) | Nonzero exit / malformed JSON / empty stdout / normal JSON | Actual Bash+jq with stubbed process |
| Reply length boundaries | [claude-discussions.yml:71](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L71) | 0 rejected;1/5999 accepted;6000/6001 rejected;Unicode counts codepoints | Actual jq |
| Reply shape and semantic fields | [claude-discussions.yml:69-71](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L69) | null/missing reply rejected;number,array,object accepted by local guard;relevantfalse/missing and is_error ignored | CLI schema assumptions remain separate; no claim real Claude emits these with exit0 |
| Post reply extraction | [claude-discussions.yml:79](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L79) | Literal metacharacters preserved;trailing newlines stripped;isolated missing reply becomes null | Post missing reply case bypasses successful Ask, so not an integrated production claim |
| Credential filter | [claude-discussions.yml:80](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L80) | All regex alternatives;19/20 boundaries;case and spaced negatives;ordinary/false-positive text | Heuristic behavior only, not proof of credential non-disclosure |
| Posting destination | [claude-discussions.yml:84](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L84) | Empty parent→discussion;nonempty→parent comment | Actual Bash argv; no comment posted |
| Post API failure | [claude-discussions.yml:85-89](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L85) | GraphQL command exits0/nonzero | gh GraphQL transport/error contract stubbed |
| Default-success downstream gating | GitHub runner assumption | Gather fails→skip Ask/Post;Ask fails→skip Post | Explicit local runner model, not actual GitHub step scheduler |
| Mutation sensitivity | Temporary copies only | Botgate,tool expansion,parentarg,secretpattern,lengthbound changes detected | Five mutations of actual snippets/expression; original files untouched |

</details>

The five workflow mutants remove the reply-parent argument, weaken the maximum-length boundary, remove a credential-pattern guard, reverse the bot gate or expand the allowed tools; the suite rejects the selected incorrect variants. This is sensitivity evidence for those oracles, not mutation completeness.

### Selected CLA dependency coverage and remaining ranges

The 12-module suite exercises configured/default inputs, contributor selection/fallback/deduplication, exact configured allowlist, ledger parsing and updates, existing/new signature decisions, bot/comment selection, status/failure paths, rerun and locking decisions. It includes C1/C2 controls, malformed ledger/API shapes, deliberately different numeric/string 404 stubs, and unconfigured option variants. HTTP-error normalization, real GitHub authentication/permissions and actual writes remain outside the stubs; the withdrawn bootstrap claim is not reinstated.

The following are V8 runtime metrics for the selected bundled code, including generated TypeScript helpers. Unexecuted locations are line intervals in the inspected bundle, not new first-party findings or a claim that each is reachable in the configured action. Range offsets are retained in `v8-selected-modules.json`; source/SDK dependencies outside these modules are excluded.

| Selected upstream module | Functions reached/reported | Ranges reached/reported | Unexecuted bundle lines |
|---|---:|---:|---|
| `checkAllowList` | 9/11 | 15/17 | 16–19, 22–24 |
| `graphql` | 14/14 | 25/27 | 62, 145 |
| `main` | 13/16 | 22/28 | 162–165, 168–170, 179, 181–182 |
| `persistence` | 16/20 | 36/45 | 280–302, 304, 306, 351, 375; intervals contain covered code too |
| `pullRerunRunner` | 26/28 | 44/47 | 397–400, 403–405, 407 |
| `pullRequestComment` | 29/29 | 49/55 | 525, 532, 542, 554, 608 |
| `pullRequestCommentContent` | 11/15 | 60/65 | 634–656; intervals contain covered code too |
| `pullRequestLock` | 14/16 | 19/25 | 761–764, 767–769, 771, 778, 780–781 |
| `signatureComment` | 17/17 | 33/35 | 819, 841 |
| `setupClaCheck` | 27/30 | 57/69 | 910–913, 916–918, 920, 927, 936, 961, 991, 1009, 1016–1017 |
| `getInputs` | 20/22 | 21/24 | 1046–1049, 1052–1054, 1056–1057 |
| `pr-sign-comment` | 3/7 | 4/9 | 1108–1130; intervals contain covered code too |

Two observed edge behaviours need a maintainer intent decision rather than an invented legal/security conclusion: the dependency's [closed-event dispatch](https://github.com/contributor-assistant/github-action/blob/ca4a40a7d1004f18d9960b404b97e5f30a505a08/src/main.ts#L15) also locks a closed, unmerged PR in the tested context; its [signing-phrase matcher](https://github.com/contributor-assistant/github-action/blob/ca4a40a7d1004f18d9960b404b97e5f30a505a08/src/pullrequest/signatureComment.ts#L65) can accept an embedded/quoted phrase when a later event causes a scan, although the first-party signing-comment trigger itself expects the exact body. Review that operational/consent wording deliberately. No claim is made that the configured exact allowlist has a wildcard vulnerability or that a missing PAT is required.

### Browser/environment matrix and unverified boundaries

Real Chromium checks cover baseline 320×568, 375×667, 768×1024, 1024×768 and 1440×900 layouts; the CSS media boundary at 859/860/861 px; and default font 16/24/32 px at widths 320/375. Two-column and three-column grids collapse at 860 and restore at 861 as intended. All four disclosures operate with Space/Enter; all 24 visible links/summaries are reachable with disclosures open and expose the declared focus style. Every visible anchor is activated while navigation is intercepted, and the actual footnote fragment scrolls to its target. External forms are neither visited/submitted nor thereby verified.

Forced-colour dark/light samples retain contrasting system text/background colours and a visible first focus outline. These are samples, not a comprehensive focus-ring/pixel audit. Initial reduced motion and JavaScript/engine absence preserve usable static marks; live preference changes remain R2. An injected throwing engine clears the first static logo before failing and leaves the other seven static: this documents an artificial robustness limit of [clearing before mounting](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L292), not a natural engine exception or another confirmed defect. Actual browser zoom, OS text scaling, screen readers, Firefox/WebKit/mobile hardware, all font/fallback combinations and arbitrary event interleavings remain untested.

## Reproducing and preserving the expanded verification

The review environment used Python 3.12.14, Node 24.19.0, Bash 5.2.37, jq 1.7, Playwright 1.62.1 and Chromium 154.0.8037.57 (Debian 13). Additional tools were pinned outside the checkout: coverage.py 7.6.1, istanbul-lib-instrument 6.0.3, istanbul-lib-coverage 3.2.2, axe-core 4.10.3 and Wrangler 4.154.0. The CLA action declares Node 20; local Node-24 VM checks do not establish identical hosted-runtime behaviour. Source copies were byte-checked before instrumentation. Only temporary copies/in-memory responses were mutated.

The commands below identify the frozen full suites; they read repository files but keep outputs under `/tmp`. Run browser/local-runtime processes with the environment's required process/socket permission, and do not substitute live `gh`, `npm` or `claude` calls for the workflow stubs. The full temporary suites are not committed, maintained or guaranteed to survive the workspace. The source-mapped matrices, versions, counts, hashes and compact reproductions in this report remain useful after those artifacts disappear.

```sh
python3 /tmp/helpandeye-generator-suite/suite.py
node /tmp/helpandeye-eye-review/driver.js --mutations
node /tmp/helpandeye-eye-review/slow-page.js
node /tmp/helpandeye-page-suite.js
node /tmp/helpandeye-expanded.js
node /tmp/helpandeye-axe-audit.js
python3 /tmp/helpandeye-security-review/extended/workflows.py
node /tmp/helpandeye-security-review/extended/cla.js
```

The page-suite command intentionally exits 1 while the F7 assertion fails. The engine driver can exit successfully while recording the two diagnostic property failures separately; read `diagnostics`, not only `passed`. Workflow/CLA passing defect-demonstration scenarios intentionally assert the wrong current outcome to make it reproducible. Do not describe these commands collectively as “all tests passed.”

<details>
<summary>Standalone local Chromium reproductions of F7 and F8</summary>

Save as `/tmp/helpandeye-browser-repro.js` and run `node /tmp/helpandeye-browser-repro.js` from the repository root. The module/executable paths below are the tested review-environment paths; adjust them to an installed Playwright/Chromium elsewhere. Requests are fulfilled from local files. The assertions deliberately verify the current defects and positive controls, not successful application requirements. This compact code was run successfully: glyph right edge 327.984375 at viewport 320; early/blink-disabled iris opacity 0 versus late opacity 1 with no hidden segments.

```js
const { chromium } = require('/opt/codex/runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const fs = require('fs'), assert = require('assert'), path = require('path');
const site = path.resolve('site');
const engine = fs.readFileSync(path.join(site, 'andeye-eye.js'), 'utf8');
(async () => {
  const browser = await chromium.launch({executablePath: '/usr/bin/chromium', args: ['--no-sandbox']});
  try {
    const page = await browser.newPage({viewport: {width: 320, height: 568}, reducedMotion: 'reduce'});
    await page.route('http://review.test/**', route => {
      const name = new URL(route.request().url()).pathname.slice(1) || 'index.html';
      return route.fulfill({status: 200, contentType: name.endsWith('.js') ? 'text/javascript' : 'text/html',
        body: fs.readFileSync(path.join(site, name))});
    });
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('Page.setFontSizes', {fontSizes: {standard: 32}});
    await page.goto('http://review.test/');
    const clipping = await page.evaluate(() => {
      const beyond = [];
      for (const span of document.querySelectorAll('.press span')) {
        const node = span.firstChild;
        if (!node || node.nodeType !== Node.TEXT_NODE) continue;
        for (let i = 0; i < node.length; i++) {
          const range = document.createRange();
          range.setStart(node, i); range.setEnd(node, i + 1);
          const rect = range.getBoundingClientRect();
          if (rect.width && rect.right > innerWidth) beyond.push(rect.right);
        }
      }
      return {root: getComputedStyle(document.documentElement).fontSize, width: innerWidth,
        overflow: getComputedStyle(document.body).overflowX, maxGlyphRight: Math.max(...beyond)};
    });
    assert.equal(clipping.root, '32px'); assert.equal(clipping.overflow, 'hidden');
    assert(clipping.maxGlyphRight > clipping.width);
    console.log('F7 reproduced', clipping);
    await page.close();
    async function drawAt(firstTimestamp, blink) {
      const p = await browser.newPage({reducedMotion: 'no-preference'});
      await p.setContent('<svg id="eye"></svg>');
      await p.evaluate(() => {window.frames = []; window.requestAnimationFrame = cb => frames.push(cb); Math.random = () => 0.5;});
      await p.addScriptTag({content: engine});
      const result = await p.evaluate(({firstTimestamp, blink}) => {
        const svg = document.querySelector('#eye'); andeyeEye(svg, {iris: 'fill', drawOn: true, blink});
        for (const t of [firstTimestamp, firstTimestamp + 16]) {
          const callbacks = frames.splice(0); for (const callback of callbacks) callback(t);
        }
        return {iris: svg.querySelector('g[clip-path]').style.opacity,
          hidden: [...svg.querySelectorAll('g[stroke] path')].filter(p => p.style.visibility === 'hidden').length};
      }, {firstTimestamp, blink});
      await p.close(); return result;
    }
    const early = await drawAt(100, true), late = await drawAt(5000, true), noBlink = await drawAt(5000, false);
    assert.equal(early.iris, '0'); assert.equal(noBlink.iris, '0');
    assert.equal(late.iris, '1'); assert.equal(late.hidden, 0);
    console.log('F8 reproduced', {early, late, noBlink});
  } finally { await browser.close(); }
})().catch(error => {console.error(error); process.exitCode = 1;});
```

</details>

<details>
<summary>Standalone C2 signature-page reproduction against the pinned dependency</summary>

Obtain the public action revision `ca4a40a7d1004f18d9960b404b97e5f30a505a08` without executing its entry point, and pass its `dist/index.js` path to this script: `node /tmp/cla-signature-repro.js /tmp/action/dist/index.js`. The script verifies the inspected bundle hash, executes its actual signature module and models the API's default 30-comment page. It makes no network request or write. Expected output is one candidate at position 30 and zero at 31. The full 89-case suite separately verifies the downstream ledger/check outcome.

```js
const fs = require('fs'), vm = require('vm'), assert = require('assert'), crypto = require('crypto');
const bundle = fs.readFileSync(process.argv[2], 'utf8');
assert.equal(crypto.createHash('sha256').update(bundle).digest('hex'),
  'a44111084c0d4782206c04b4276292f7fec6d1f7a33525512fbeef3242079dfb');
const header = bundle.indexOf('/***/ 1905:');
const start = bundle.indexOf('\n"use strict";', header), end = bundle.indexOf('\n/***/ }),', start);
assert(header >= 0 && start > header && end > start);
const sign = 'I have read the CLA Document and I hereby sign the CLA';
(async () => {
  for (const position of [30, 31]) {
    const comments = Array.from({length: 31}, (_, i) => ({id: i + 1,
      user: {id: i + 1 === position ? 2 : 9, login: i + 1 === position ? 'signer' : 'reader'},
      body: i + 1 === position ? sign : 'ordinary discussion', created_at: '2026-10-28T00:00:00Z'}));
    let calls = 0;
    const dependencies = {
      3258: {octokit: {issues: {listComments: async args => {
        calls++; assert.equal(args.page, undefined); assert.equal(args.per_page, undefined);
        return {data: comments.slice(0, 30)};
      }}}},
      5438: {context: {payload: {repository: {id: 1}}, repo: {owner: 'fixture', repo: 'fixture'}, issue: {number: 1}}},
      3611: {getUseDcoFlag: () => 'false', getCustomPrSignComment: () => ''}
    };
    const exports = {};
    vm.runInNewContext(bundle.slice(start, end), {exports, __nccwpck_require__: id => {
      assert(id in dependencies); return dependencies[id];
    }});
    const user = {id: 2, name: 'signer'};
    const result = await exports.default({notSigned: [user]}, [user]);
    assert.equal(calls, 1); assert.equal(result.newSigned.length, position === 30 ? 1 : 0);
    console.log({signaturePosition: position, calls, recordedCandidates: result.newSigned.length});
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
```

</details>

<details>
<summary>Small independent generator coverage collector</summary>

With coverage.py 7.6.1 importable, run the following from the repository root. It copies the generator to a new temporary directory and exercises both import and CLI at the same measured path. It independently reproduces 79/79 statements and 22/22 measured branches. Its deliberately small assertion set is **not** the seven-group property suite: reaching the metric with few checks illustrates why coverage alone does not establish correct geometry or every filesystem failure.

```python
import json, pathlib, runpy, shutil, tempfile
import coverage  # pinned 7.6.1 for the reported measurement
work = pathlib.Path(tempfile.mkdtemp(prefix='helpandeye-coverage-', dir='/tmp'))
target = work / 'gen_mark.py'
shutil.copyfile('assets/brand/gen_mark.py', target)
cov = coverage.Coverage(branch=True, include=[str(target)], data_file=str(work / '.coverage'))
cov.start()
api = runpy.run_path(str(target))
for background in ('#131826', None):
    assert '<svg' in api['mark'](background)
for appearance in ('any', 'dark', 'tinted'):
    for platform in ('ios', 'mac'):
        assert 'viewBox="0 0 1024 1024"' in api['icon'](appearance, platform)
runpy.run_path(str(target), run_name='__main__')
cov.stop()
cov.save()
cov.json_report(outfile=str(work / 'coverage.json'))
print(work, json.loads((work / 'coverage.json').read_text())['totals'])
```

</details>

<details>
<summary>Small JavaScript source-coverage collection example</summary>

This standalone example shows the exact instrumentation/collection method and returns its own missing branch arms. It exercises only a small static API subset, so it **does not reproduce the full 74-case totals**: the validated example reaches 22/26 functions and 75/108 branches. The full matrix adds defaults, tuning, draw boundaries, clocks and controlled animation phases; its independent result is 26/26 functions and 107/108 branches. This collector uses the pinned tool paths from the review; substitute installed equivalent modules if needed. For V8-only metrics, collect an unmodified source in a separate context rather than counting Istanbul's inserted helper code.

```js
const fs = require('fs'), path = require('path');
const {chromium} = require('/opt/codex/runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const {createInstrumenter} = require('/tmp/helpandeye-istanbul-tool/node_modules/istanbul-lib-instrument');
const {createCoverageMap} = require('/tmp/helpandeye-istanbul-tool/node_modules/istanbul-lib-coverage');
const sourcePath = path.resolve('site/andeye-eye.js');
const code = createInstrumenter({compact: false}).instrumentSync(fs.readFileSync(sourcePath, 'utf8'), sourcePath);
(async () => {
  const browser = await chromium.launch({executablePath: '/usr/bin/chromium', args: ['--no-sandbox']});
  try {
    const page = await browser.newPage({reducedMotion: 'reduce'});
    await page.setContent('<body></body>'); await page.addScriptTag({content: code});
    await page.evaluate(() => {
      for (const iris of ['none', 'fill', 'stroke']) {
        for (const glyph of [null, 'clock', 'tick', 'people', 'calendar', 'code']) {
          const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
          document.body.appendChild(svg);
          const api = andeyeEye(svg, {iris, glyph, blink: false});
          api.setPose(0, 0.5); api.setPose(1, 1); api.setWink(0);
        }
      }
    });
    const map = createCoverageMap(await page.evaluate(() => window.__coverage__));
    const result = map.fileCoverageFor(sourcePath).toJSON();
    console.log(JSON.stringify({summary: map.fileCoverageFor(sourcePath).toSummary().toJSON(),
      missingBranchArms: Object.entries(result.b).flatMap(([id, counts]) => counts.flatMap((count, arm) =>
        count ? [] : [{line: result.branchMap[id].line, type: result.branchMap[id].type, arm}]))}, null, 2));
  } finally {await browser.close();}
})().catch(error => {console.error(error); process.exitCode = 1;});
```

</details>

For local Cloudflare reproduction, copy `wrangler.jsonc` and all five `site/` files into a temporary project, install `wrangler@4.154.0` into a separate temporary tool directory with a temporary npm cache, disable metrics and keep configuration/log/state directories under `/tmp`. From the **copied** project's directory, the tested command shape is:

```sh
WRANGLER_SEND_METRICS=false /tmp/tool/node_modules/.bin/wrangler dev \
  --local --config /tmp/project/wrangler.jsonc --persist-to /tmp/persist \
  --ip 127.0.0.1 --port 18787 --inspector-port 19229 \
  --show-interactive-dev-session=false
```

Repeat with `--env dev`, a distinct state directory and distinct ports. Check GET `/`, `/andeye-eye.js`, `/favicon.svg`, `/apple-touch-icon.png`, `/og.png`, `/index.html`, `/missing`, `/missing/`, `/favicon.svg/` and `/nested/index.html` without following redirects when testing the 307. Stop both processes and verify the loopback ports close. No login, deploy, public tunnel, real binding or Cloudflare account configuration is needed. Local `Request.cf` placeholder behaviour does not verify production request metadata.

<details>
<summary>Frozen temporary artifact identifiers</summary>

SHA-256 values identify the measured artifacts; they do not turn external review scripts into repository tests. Full original/diagnostic results, per-case stdout/stderr, raw CDP data, all uncovered upstream ranges, screenshots and mutation files remain in the corresponding directories for this workspace session.

| Artifact | Purpose | SHA-256 |
|---|---|---|
| `/tmp/helpandeye-eye-review/driver.js` | engine runner / mutations | `7379ee28ea0555fa813a2ad380ec8087c29fc4bdccfec1547a9c9bbbeb3bfeec` |
| `/tmp/helpandeye-eye-review/suite.js` | engine contract oracles | `d589e62a3beab1a2a81b17771e40e27a72c40d602397f32607e79cb50d06a110` |
| `/tmp/helpandeye-eye-review/coverage-summary.json` | original V8 source ranges | `a092eadcd34d84617be53b33e80fefa00b8113d74783656a5a471925593e6776` |
| `/tmp/helpandeye-eye-review/slow-page.js` | unchanged-page slow-load reproduction | `f4ff2ef5b80cd9255e21a7fb8aa6ec97dde17416101738c5057f65534131b368` |
| `/tmp/helpandeye-generator-suite/suite.py` | generator property/CLI suite | `6864c67c7de19991d807693d221f4cdbb15c28a15cfa0585f3fff8cc5b630bf3` |
| `/tmp/helpandeye-generator-coverage.json` | independent coverage.py result | `217490af15099514f66f76383e4030570c7277fc9cf045914af7114abbd7c978` |
| `/tmp/helpandeye-source-coverage-audit/coverage-summary.json` | independent Istanbul results | `fc1632f6c262a9cbd8a562549246e52f3ec2622e7499c60f816680c9b68fc528` |
| `/tmp/helpandeye-page-suite.js` | page integration / negative controls | `7a297c341ec521b56d0aa16cfb561621164e1b1a3d31ae24a2ffcdca27cccb60` |
| `/tmp/helpandeye-axe-summary.json` | three-scenario automated accessibility summary | `bfa8bd8f48b37c98e686a39536b65199b265aba5d2259ed777cd3e3b76eb6671` |
| `/tmp/helpandeye-security-review/extended/workflows.py` | workflow scripts / expression models | `6e436841b40fa23f91e5547ef4e8528d81abad30c314aa2a360473f6c35d6325` |
| `/tmp/helpandeye-security-review/extended/cla.js` | selected dependency implementation suite | `20c77de645dc3fef3748fe071b95d76e8d3d57fa577dcd29f61d2bc63984fc9b` |
| `/tmp/helpandeye-security-review/extended/artifact-hashes.json` | frozen security-suite/result manifest | `99ef7c564c5d5b432639613cdf3934ef3925ce873ab4aac53040e5605dc0f8ed` |
| `/tmp/helpandeye-wrangler-check/default-http.json` | default local runtime responses | `142fa1b57f49dd5a949a8b68ab6428e8a2108f9c9ebd2dabe4f04d4aa95b669d` |
| `/tmp/helpandeye-wrangler-check/dev-http.json` | dev local runtime responses | `142fa1b57f49dd5a949a8b68ab6428e8a2108f9c9ebd2dabe4f04d4aa95b669d` |

</details>

## Per-file coverage inventory

“Full text” means the team read the file's complete content, rather than relying solely on searches or metadata. Every tracked file also received a mechanical inventory/encoding check where applicable. Generated artwork was reviewed as text/XML as well as for its relationship to the generator. Domain abbreviations: **S** safety/specification, **C** security/CI/governance, **W** website/accessibility, **A** assets/mechanical; coordinator and parent cross-checks overlap these domains.

| Tracked file | Review and result |
|---|---|
| [.github/claude/discussion-prompt.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/claude/discussion-prompt.md?plain=1#L1) | C, full text; trust boundary, public safety advice, source/decision distinction; R3. |
| [.github/workflows/cla.yml](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/cla.yml#L1) | C, full text; YAML/action source, configured conditions and selected-module execution; C1/C2/R4. |
| [.github/workflows/claude-discussions.yml](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.github/workflows/claude-discussions.yml#L1) | C, full text; trigger, permissions, quoting, prompt, tools, output and reply logic; syntax and fixtures; F5/R1/R3. |
| [.gitignore](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/.gitignore#L1) | C/A, full text; runtime exclusions; no material finding. |
| [AGENTS.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/AGENTS.md?plain=1#L1) | All domains, full text; safety, verification and authority constraints; F1/F2 and design gates. |
| [CHANGELOG.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CHANGELOG.md?plain=1#L1) | S/C/A, full text; chronology reconciled with current source; F1/F6. Historical entries were not mistaken for current behaviour. |
| [CLA.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CLA.md?plain=1#L1) | C, full text; version, representations, rights and summary consistency; governance observations, no legal opinion. |
| [CONTRIBUTING.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CONTRIBUTING.md?plain=1#L1) | All domains, full text; privacy, testing, style, licence/CLA; F1 and verification-scope recommendation. |
| [CONTRIBUTORS.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/CONTRIBUTORS.md?plain=1#L1) | C, full text; contributor/CLA instructions; no material finding. |
| [LICENSE](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/LICENSE#L1) | C, full text; AGPL-3.0 present; not a third-party dependency or legal-compliance audit. |
| [README.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/README.md?plain=1#L1) | S/C/W, full text; maturity, routing, privacy, hardware, deployment and public claims; F2/F3/R4. |
| [assets/brand/README.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/README.md?plain=1#L1) | A, full text; brand and generation instructions; F6/export recommendation. |
| [assets/brand/gen_mark.py](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/gen_mark.py#L1) | A, full text; all nine functions, property/CLI/mutation suite and independent coverage.py measurement; seven matching outputs; F6. |
| [assets/brand/svg/help-mark-panel.svg](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/svg/help-mark-panel.svg#L1) | A, full text/XML; byte-identical regeneration; no additional finding. |
| [assets/brand/svg/help-mark-white.svg](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/svg/help-mark-white.svg#L1) | A, full text/XML; byte-identical regeneration; no additional finding. |
| [assets/brand/svg/icon-ios-any.svg](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/svg/icon-ios-any.svg#L1) | A, full text/XML; byte-identical regeneration; no additional finding. |
| [assets/brand/svg/icon-ios-dark.svg](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/svg/icon-ios-dark.svg#L1) | A, full text/XML; byte-identical regeneration; no additional finding. |
| [assets/brand/svg/icon-ios-tinted.svg](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/svg/icon-ios-tinted.svg#L1) | A, full text/XML; byte-identical regeneration and mask structure; no additional finding. |
| [assets/brand/svg/icon-mac-any.svg](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/svg/icon-mac-any.svg#L1) | A, full text/XML; byte-identical regeneration; no additional finding. |
| [assets/brand/svg/icon-mac-dark.svg](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/svg/icon-mac-dark.svg#L1) | A, full text/XML; byte-identical regeneration; no additional finding. |
| [assets/brand/svg/icon-whatsapp.svg](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/assets/brand/svg/icon-whatsapp.svg#L1) | A, full text/XML; legacy colour/cross and absent generator output; F6. |
| [docs/app-spec.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/app-spec.md?plain=1#L1) | S/W and independent challenge, full text; F1/F2/F3 plus protocol/platform/operations design gates. |
| [docs/design-decisions.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/docs/design-decisions.md?plain=1#L1) | S/C/W, full text; cross-document authority, rationale and already acknowledged questions; F1/F2. |
| [site/andeye-eye.js](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/andeye-eye.js#L1) | W/S, full text; all 26 function literals, API/geometry/raster/state/timing/mutation cases, V8 and independent AST coverage; F8/R2/provenance recommendation. |
| [site/apple-touch-icon.png](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/apple-touch-icon.png) | A/W/parent, metadata, decode and visual inspection; 180×180, opaque; no apparent corruption. |
| [site/favicon.svg](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/favicon.svg#L1) | A/W, full text/XML; generator-function comparison and local/browser asset reference; no material finding. |
| [site/index.html](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/index.html#L1) | S/W, full text; three inline functions/both condition outcomes, copy, CSS, keyboard, layouts/fonts/preferences, no-JS, axe and contrast; F2/F3/F4/F7/R2/R5 and semantic cleanup. |
| [site/og.png](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/site/og.png) | A/W/parent, metadata, decode and visual inspection; 1200×630; matches declared size, no apparent corruption. |
| [tests/MANUAL-TESTS.md](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/tests/MANUAL-TESTS.md?plain=1#L1) | S, full text; deliberately empty prototype-stage template; no hardware coverage claimed. |
| [wrangler.jsonc](https://github.com/andeyePro/helpandeye/blob/1119a0377bbb1671c1cdfeafb595bbed439b5f8e/wrangler.jsonc#L1) | C/A, full text; JSON parse and successful Wrangler/workerd local startup/asset/redirect/404 checks in both default and dev; no production deployment/service-state verification. |

## Remediation order and remaining verification

1. **Before protocol implementation or any reliance-based trial:** resolve F1/F2 and write the request/acknowledgement/failure-state contract, authentication/key lifecycle, offline escalation owner, radio budget and supported mobile alert conditions. Convert the design-gate examples into acceptance criteria. Keep the no-automatic-closure and emergency-services rules intact.
2. **For the current public information site:** fix F3/F4/F7, shorten/control blinking, qualify privacy and route claims, and address disclosure/footnote semantics (R5). Recheck normal/hover/focus, reduced motion including changes after load, no-JS and enlarged-text layouts, then conduct screen-reader and representative-user checks.
3. **For repository automation:** fix F5/C1/C2, establish bot usage limits, pin/review privileged dependencies and verify CLA storage against production branch protections. Test in a controlled repository before enabling changed write behaviour.
4. **For maintenance:** fix F8, reconcile all generated assets and document exports, provenance and a maintained website/workflow regression path. Temporary review harnesses do not add that maintained coverage to the original snapshot.

**Not run or not established:** real Heltec boards, buttons, pendant links, power loss, battery endurance, sound/vibration, range/interference, airtime/duty-cycle measurements, actual phones/watches, mobile app background/lifecycle behaviour, notification entitlements, protocol cryptography, relay/push/SMS integration, cloud failover/quota exhaustion, live bot responses, live CLA signing, branch protections or actual Workers Builds configuration. There is no product implementation/test runner for those planned paths. No screen reader, real mobile device, formal HTML validator, complete WCAG conformance assessment, standards certification or legal analysis was performed. The described axe audits and local Wrangler/workerd checks did run; they do not establish production/cloud or assistive-technology behaviour. Browser tests used Chromium and the enumerated viewport/font/preference cases, not actual browser zoom, OS text scaling, every browser or every input/interleaving.

External destination functionality remains unverified: several restricted requests failed because the configured proxy was unavailable, and the contact/main andeye hosts were outside the permitted network policy. Later permitted upstream-source reads succeeded with TLS verification intact. Local link existence and local HTTP/browser passes do not establish that waitlist/volunteer forms, external legal pages or production deployment settings work.

Only this report was authorised as a repository change. The original 30-file source snapshot remains the reviewed subject; no fixes are represented as already implemented.

**Independent final source-integrity audit:** HEAD remained at the reviewed commit; SHA-256 hashes of all 30 original tracked files were unchanged; the inventory matched those 30 files exactly; source citation targets and line bounds were checked. The only repository change was the additional untracked `CodexReview.md`, with no ignored untracked files. No original source changes, commits, pushes or deployments were made.


</details>
