import XCTest
@testable import HelpAndICore

/// Random interleavings of presses, acknowledgements, membership changes, links going up and
/// down, lost packets and clock jumps across a group of phones, checking the safety rules after
/// every step. Every run is repeatable from its seed. HELPANDI_FUZZ_SEEDS=n runs more seeds.
@MainActor final class EngineFuzzTests: XCTestCase {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @MainActor final class World {
        let air = Air()
        let clock = Clock()
        var phones: [Phone] = []
        var coordinator: Phone { phones[0] }
        /// (unit, request, responder) for every acknowledgement a person actually made.
        var humanAcks: Set<String> = []
        /// Phones taken out of the group; nothing about them is checked any more.
        var gone: Set<ObjectIdentifier> = []
        var removedNumbers: Set<UInt16> = []
        var lossRate = 0.0
        var log: [String] = []
    }

    func testRandomInterleavingsKeepTheSafetyRules() async throws {
        let seeds = Int(ProcessInfo.processInfo.environment["HELPANDI_FUZZ_SEEDS"] ?? "") ?? 60
        for seed in 1...seeds {
            try await run(seed: UInt64(seed), steps: 250)
        }
    }

    func join(_ w: World, _ p: Phone, call: Bool, respond: Bool) {
        let c = w.coordinator.engine!
        let invite = Joining.invitation(for: c.group!, coordinator: w.coordinator.identity)
        let request = Joining.request(invite, name: "P", call: call, respond: respond, me: p.identity)
        var welcome: Joining.Welcome?
        c.updateGroup { g in welcome = try! Joining.admit(request, to: &g, invite: invite, coordinator: w.coordinator.identity) }
        p.engine.joined(try! Joining.open(welcome!, invite: invite, me: p.identity), as: welcome!.memberNumber)
    }

    func run(seed: UInt64, steps: Int) async throws {
        var rng = SplitMix64(state: seed)
        let w = World()
        let n = Int.random(in: 4...6, using: &rng)
        for _ in 0..<n { w.phones.append(Phone(air: w.air, clock: w.clock)) }
        w.coordinator.engine.createGroup(name: "Fuzz", myName: "C", call: Bool.random(using: &rng))
        for (i, p) in w.phones.enumerated().dropFirst() {
            let role = i % 3
            join(w, p, call: role != 1, respond: role != 0)
        }
        await w.air.run()
        for p in w.phones { await p.engine.boxReady() }
        await w.air.run()
        w.air.keep = { [unowned w] _, _, _ in w.lossRate == 0 || Double.random(in: 0..<1) >= w.lossRate }

        for step in 0..<steps {
            let action = Int.random(in: 0..<100, using: &rng)
            let live = w.phones.filter { !w.gone.contains(ObjectIdentifier($0)) && $0.engine.me != nil }
            // A removed phone keeps going: it acknowledges what it heard, and replays signed
            // messages it captured. None of it may ever count.
            if let bad = w.phones.filter({ w.gone.contains(ObjectIdentifier($0)) }).randomElement(using: &rng), Int.random(in: 0..<4, using: &rng) == 0 {
                if let r = bad.engine.activity.inbox.sorted.randomElement(using: &rng) { bad.engine.acknowledge(r.key) }
                if let f = w.air.groupSends.filter({ if case .signed = $0 { return true }; if case .ack = $0 { return true }; return false }).randomElement(using: &rng) {
                    for q in live { q.engine.receive(f, via: .mesh) }
                }
                if let mine = bad.engine.activity.inbox.requests.values.first, let me = bad.engine.saved?.me, let g = bad.engine.group {
                    let forged = HelpFrame.signedAck(unit: mine.key.unit, request: mine.key.request, responder: me, at: w.clock.now,
                                                     identity: bad.identity, group: g.secrets.groupID)
                    for q in live { q.engine.receive(forged, via: .mesh) }
                }
            }
            guard let p = live.randomElement(using: &rng) else { break }
            switch action {
            case 0..<18:
                let colour = [Colour.red, .red, .amber, .green].randomElement(using: &rng)!
                p.engine.press(colour)
                w.log.append("\(step): \(p.engine.saved!.me) presses \(colour)")
            case 18..<36:
                if let r = p.engine.activity.inbox.sorted.first(where: { !$0.isAcknowledged }) ?? p.engine.activity.inbox.sorted.randomElement(using: &rng),
                   p.engine.acknowledge(r.key) {
                    w.humanAcks.insert("\(r.key.unit)-\(r.key.request)-\(p.engine.saved!.me)")
                    w.log.append("\(step): \(p.engine.saved!.me) acknowledges \(r.key)")
                }
            case 36..<40:
                if let r = p.engine.activity.inbox.requests.values.first(where: { $0.acknowledgedBy.contains(p.engine.saved!.me) }) {
                    p.engine.retryAck(r.key)
                }
            case 40..<46:
                p.engine.setAvailable(Bool.random(using: &rng), hours: Double.random(in: 0.1...24, using: &rng))
            case 46..<50:
                let c = w.coordinator.engine!
                if let m = c.group?.members.filter({ $0.role == .responder || $0.role == .both }).randomElement(using: &rng) {
                    c.promote(m.number)
                    w.log.append("\(step): promote \(m.number)")
                }
            case 50..<53:
                let c = w.coordinator.engine!
                if live.count > 3, let victim = live.filter({ $0 !== w.coordinator }).randomElement(using: &rng), let num = victim.engine.saved?.me {
                    c.removeMember(num)
                    w.gone.insert(ObjectIdentifier(victim))
                    w.removedNumbers.insert(num)
                    w.log.append("\(step): remove \(num)")
                }
            case 53..<63:
                p.mesh.isReady.toggle()
                w.log.append("\(step): \(p.engine.saved!.me) mesh \(p.mesh.isReady)")
            case 63..<70:
                p.relay.isConfigured.toggle()
            case 70..<75:
                w.lossRate = [0, 0, 0.3, 0.8, 1].randomElement(using: &rng)!
            case 75..<80:
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: _ = p.engine.addNote("Back door open")
                case 1: p.engine.sharePosition(latitude: 55.4, longitude: -4.5, accuracy: 10)
                default:
                    let t = Int.random(in: 0..<1440, using: &rng)
                    p.engine.setCheckIn(Bool.random(using: &rng) ? CheckInSchedule(times: [t]) : nil)
                }
            default:
                let jump: TimeInterval = [1, 15, 30, 60, 120, 600, 3600, 86_401].randomElement(using: &rng)!
                w.clock.now = w.clock.now.addingTimeInterval(jump)
                for q in w.phones { q.engine.tick() }
            }
            await w.air.run()
            try check(w, seed: seed, step: step)
        }

        // Heal: everything up, no loss, time passes, boxes reconnect.
        w.lossRate = 0
        for p in w.phones { p.mesh.isReady = true; p.relay.isConfigured = true }
        for _ in 0..<4 {
            w.clock.now = w.clock.now.addingTimeInterval(86_400 + 1)
            for p in w.phones { p.engine.tick(); await p.engine.boxReady() }
            await w.air.run()
        }
        try check(w, seed: seed, step: steps)
        let stayed = w.phones.filter { !w.gone.contains(ObjectIdentifier($0)) && $0.engine.me != nil }
        let versions = Set(stayed.map { $0.engine.group!.membershipVersion })
        let rosters = Set(stayed.map { Set($0.engine.group!.members.map(\.number)) })
        XCTAssertEqual(versions.count, 1, "seed \(seed): phones disagree on the membership version: \(versions)\n" + w.log.suffix(30).joined(separator: "\n"))
        XCTAssertEqual(rosters.count, 1, "seed \(seed): phones disagree on who is in the group: \(rosters)\n" + w.log.suffix(30).joined(separator: "\n"))
    }

    func check(_ w: World, seed: UInt64, step: Int) throws {
        func fail(_ why: String) throws {
            XCTFail("seed \(seed), step \(step): \(why)\n" + w.log.suffix(25).joined(separator: "\n"))
            throw CancellationError()
        }
        if let v = w.air.violations.first { try fail(v) }
        // Nothing personal on the shared group channel.
        if let f = w.air.groupSends.first(where: { !$0.mayGoOnGroupChannel }) { try fail("personal frame on the group channel: \(f)") }
        for p in w.phones where !w.gone.contains(ObjectIdentifier(p)) {
            guard let g = p.engine.group else { continue }
            // Help is confirmed only by a person: every acknowledgement anywhere is one a person made.
            for r in p.engine.activity.outgoing {
                // A removed phone's ack can count only on a phone that has not yet heard of the removal.
                for who in r.acknowledgedBy where !w.humanAcks.contains("\(r.unit)-\(r.number)-\(who)") && (g.member(who) == nil || !w.removedNumbers.contains(who)) {
                    try fail("caller shown seen by \(who) for \(r.unit)-\(r.number) without that person acknowledging; "
                             + "\(who) is \(g.member(who) == nil ? "not" : "still") in this caller's group; this phone is member "
                             + "\(p.engine.saved!.me) with unit \(String(describing: p.engine.me?.unit)), removed: \(g.removedMembers.sorted())")
                }
            }
            for r in p.engine.activity.inbox.requests.values {
                for who in r.acknowledgedBy where !w.humanAcks.contains("\(r.key.unit)-\(r.key.request)-\(who)") && (g.member(who) == nil || !w.removedNumbers.contains(who)) {
                    try fail("request \(r.key) marked acknowledged by \(who), who never did")
                }
                // An open call keeps alerting on this responder's phone.
                if !r.isAcknowledged, r.colour != .green, p.engine.me?.canRespond == true,
                   (p.alerts.scheduled[r.key]?.times.isEmpty ?? true), r.key.unit != p.engine.me?.unit {
                    try fail("open request \(r.key) has no alerts on member \(p.engine.saved!.me)")
                }
            }
            // No two members share a number or a unit.
            let numbers = g.members.map(\.number), units = g.members.compactMap(\.unit)
            if Set(numbers).count != numbers.count { try fail("duplicate member numbers \(numbers)") }
            if Set(units).count != units.count { try fail("duplicate units \(units)") }
            // Within the IR 2030 duty cycle, with the margin the budget keeps.
            if let a = p.engine.activity.airtime, a.used(at: w.clock.now) > a.dutyCycle * 3600 * 0.9 + 2 {
                try fail("airtime \(a.used(at: w.clock.now)) s over the limit")
            }
        }
        // Every phone that holds a number agrees on whose key it is.
        var keys: [UInt16: Data] = [:]
        for p in w.phones where !w.gone.contains(ObjectIdentifier(p)) {
            for m in p.engine.group?.members ?? [] {
                if let k = m.signingKey, let seen = keys[m.number], seen != k { try fail("member \(m.number) has two different keys on different phones") }
                if let k = m.signingKey { keys[m.number] = k }
            }
        }
    }
}
