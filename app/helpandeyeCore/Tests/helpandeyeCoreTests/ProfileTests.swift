import XCTest
@testable import helpandeyeCore

final class ProfileTests: XCTestCase {
    /// The same settings always make the same bytes, whatever order they were set in, so whether
    /// they fit the radio never depends on chance.
    func testTheSameSettingsAlwaysMakeTheSameBytes() throws {
        var a = GroupState.StoredPolicy(), b = GroupState.StoredPolicy()
        for m in UInt16(1)...40 { a.boxHome[m] = m + 100; a.profileOf[m] = UInt8(m % 3) }
        for m in (UInt16(1)...40).reversed() { b.profileOf[m] = UInt8(m % 3); b.boxHome[m] = m + 100 }
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        let ea = try e.encode(a), eb = try e.encode(b)
        XCTAssertEqual(ea, eb)
        let back = try JSONDecoder().decode(GroupState.StoredPolicy.self, from: e.encode(a))
        XCTAssertEqual(back.boxHome, a.boxHome)
        XCTAssertEqual(back.profileOf, a.profileOf)
    }

    func testTheStandardProfile() {
        let p = Profile.standard
        XCTAssertEqual(p.face, .wordsAndSymbol, "words and a symbol together by default")
        XCTAssertEqual(p.symbol(.red), "hand.raised.fill")
        XCTAssertEqual(p.notSent, .eehOoh)
        XCTAssertEqual(p.afterOK, .stopsRepeats, "new groups start on B")
        XCTAssertFalse(p.callerMayClose)
        XCTAssertFalse(p.mayChange(.buttons))
        XCTAssertTrue(p.mayChange(.sounds))
    }

    func testOwnChoicesCountOnlyWhereTheProfileAllows() {
        var p = Profile(id: 1, name: "Living alone")
        p.personMayChange = [.sounds]
        var own = p
        own.soundsAndSpeech = false
        own.afterOK = .closesCall
        own.shareWhere = true
        let applied = p.applying(own)
        XCTAssertFalse(applied.soundsAndSpeech)
        XCTAssertEqual(applied.afterOK, .stopsRepeats)
        XCTAssertFalse(applied.shareWhere)
    }

    func testEachMemberHasTheirProfileOrTheFirst() {
        var g = GroupState(name: "Mill Lane", secrets: .random(), members: [
            Member(number: 1, name: "Sam", role: .coordinator, publicKey: Data(count: 32)),
            Member(number: 2, name: "Pat", role: .caller, publicKey: Data(count: 32), unit: 70001),
        ])
        var lone = Profile(id: g.nextProfileID!, name: "Lone worker")
        lone.redInterval = 60
        g.policy.profiles.append(lone)
        XCTAssertEqual(g.profile(of: 2).name, "Standard")
        g.policy.profileOf[2] = lone.id
        XCTAssertEqual(g.profile(ofUnit: 70001).name, "Lone worker")
        XCTAssertEqual(g.escalationPolicy(forUnit: 70001).redInterval, 60)
        XCTAssertEqual(g.escalationPolicy(forUnit: 70009).redInterval, 120)
        g.policy.profiles.removeAll { $0.id == lone.id }
        XCTAssertEqual(g.profile(of: 2).name, "Standard", "a profile that has gone falls back to the first")
    }

    func testAGroupSavedBeforeProfilesKeepsItsWordsAndTimes() throws {
        let old = try JSONDecoder().decode(GroupState.StoredPolicy.self, from: Data(#"{"useDistance":false,"redInterval":60,"amberInterval":600,"buttonWords":{"red":"Come now"}}"#.utf8))
        XCTAssertEqual(old.profiles.count, 1)
        XCTAssertEqual(old.profiles[0].redInterval, 60)
        XCTAssertEqual(ButtonWords.words(.red, in: old.profiles[0]), "Come now")
        XCTAssertTrue(old.keepsLog)
        let again = try JSONDecoder().decode(GroupState.StoredPolicy.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(again, old)
    }

    /// A unit's antenna is part of the group's settings: it goes to every member with them, a
    /// group saved before it loads with the standard whip, and the cap follows from it.
    func testAUnitsAntennaIsInTheSettingsAndGivesItsCap() throws {
        let coordinator = DeviceIdentity()
        var g = GroupState(name: "Mill Lane", secrets: .random(), members: [
            Member(number: 1, name: "Sam", role: .coordinator, publicKey: coordinator.publicKey, signingKey: coordinator.signingPublicKey),
            Member(number: 2, name: "Pat", role: .caller, publicKey: Data(count: 32), unit: 70001),
        ])
        XCTAssertEqual(g.antenna(of: 2), .standardWhip)
        XCTAssertEqual(g.maxRadioSetting(ofUnit: 70001, in: Band.all[1]), 15)
        g.policy.antennaOf[2] = .external(gainDBi: 6)
        XCTAssertEqual(g.maxRadioSetting(ofUnit: 70001, in: Band.all[1]), 11)
        XCTAssertEqual(g.settings.changes(from: GroupSettings(policy: .init(), relayURL: nil)), ["changed a unit's antenna"])
        g.settingsVersion = 1
        let frame = try XCTUnwrap(g.settingsFrame(as: 1, identity: coordinator))
        var copy = g
        copy.policy = .init()
        copy.settingsVersion = 0
        XCTAssertTrue(copy.apply(settings: frame))
        XCTAssertEqual(copy.antenna(of: 2), .external(gainDBi: 6))
        let old = try JSONDecoder().decode(GroupState.StoredPolicy.self, from: Data(#"{"useDistance":false,"profiles":[],"profileOf":{},"keepsLog":true}"#.utf8))
        XCTAssertTrue(old.antennaOf.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(GroupState.StoredPolicy.self, from: JSONEncoder().encode(g.policy)), g.policy)
    }

    func testSeveralProfilesFitOneSignedSettingsFrame() {
        let coordinator = DeviceIdentity()
        var g = GroupState(name: "Mill Lane", secrets: .random(), members: [
            Member(number: 1, name: "Sam", role: .coordinator, publicKey: coordinator.publicKey, signingKey: coordinator.signingPublicKey),
        ])
        for (i, name) in ["Living alone", "Lone worker", "Walking"].enumerated() {
            var p = Profile(id: UInt8(i + 1), name: name)
            for c in Colour.allCases { ButtonWords.set(String(repeating: "w", count: 40), for: ButtonWords.key(c), in: &p) }
            p.checkIns = CheckInSchedule(times: [540, 1260])
            g.policy.profiles.append(p)
        }
        g.settingsVersion = 1
        g.relayPass = "1.\(RelayProtocol.id(of: g.secrets.groupID)).1800000000.\(String(repeating: "A", count: 86))"
        guard let frame = g.settingsFrame(as: 1, identity: coordinator) else { return XCTFail("settings too big for a frame") }
        XCTAssertEqual(HelpFrame(frame.encoded()), frame)
        var copy = g
        copy.policy = .init()
        copy.settingsVersion = 0
        copy.relayPass = nil
        XCTAssertTrue(copy.apply(settings: frame))
        XCTAssertEqual(copy.policy, g.policy)
        XCTAssertEqual(copy.relayPass, g.relayPass, "the pass travels with the settings")
    }

    func testSettingsFromAPhoneBeforeProfilesKeepTheGroupsProfiles() throws {
        let coordinator = DeviceIdentity()
        var g = GroupState(name: "Mill Lane", secrets: .random(), members: [
            Member(number: 1, name: "Sam", role: .coordinator, publicKey: coordinator.publicKey, signingKey: coordinator.signingPublicKey),
        ])
        g.policy.profiles.append(Profile(id: 1, name: "Lone worker"))
        g.policy.profileOf[2] = 1
        let pass = "1.\(RelayProtocol.id(of: g.secrets.groupID)).1800000000.\(String(repeating: "A", count: 86))"
        g.relayPass = pass
        let plain = Data(#"{"policy":{"useDistance":false,"redInterval":120,"amberInterval":900},"relayURL":"https://new.example"}"#.utf8)
        let sig = try coordinator.signingKey.signature(for: GroupState.settingsInput(group: g.secrets.groupID, signer: 1, version: 1, settings: plain))
        XCTAssertTrue(g.apply(settings: .groupSettings(signer: 1, version: 1, settings: plain, signature: sig)), "an older phone's change still counts")
        XCTAssertEqual(g.relayURL, "https://new.example")
        XCTAssertEqual(g.relayPass, pass, "settings from before passes do not take the group's away")
        XCTAssertEqual(g.policy.profiles.map(\.name), ["Standard", "Lone worker"])
        XCTAssertEqual(g.policy.profileOf[2], 1)
    }

    /// A group with every setting an older version may not send: antennas, power-cut choices,
    /// names on boxes and boxes' homes.
    private func groupWithBoxSettings(_ coordinator: DeviceIdentity, me: DeviceIdentity? = nil) -> GroupState {
        var g = GroupState(name: "Mill Lane", secrets: .random(), members: [
            Member(number: 1, name: "Sam", role: .coordinator, publicKey: coordinator.publicKey, signingKey: coordinator.signingPublicKey),
            Member(number: 2, name: "Pat", role: .both, publicKey: me?.publicKey ?? Data(count: 32), unit: 70002),
            Member(number: 4, name: "Box", role: .caller, publicKey: Data(count: 32), unit: 70004),
        ])
        g.policy.antennaOf[4] = .external(gainDBi: 3)
        g.policy.reportsPowerCut = [4]
        g.policy.namesOnBox = true
        g.policy.boxHome[4] = 2
        return g
    }

    /// `json` with the box settings left out of its policy, as the version before them sent it,
    /// and as the version before this one sent them when empty.
    private func asOlderVersion(_ json: Data) throws -> Data {
        var top = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        var policy = try XCTUnwrap(top["policy"] as? [String: Any])
        for k in ["antennaOf", "reportsPowerCut", "namesOnBox", "boxHome"] { policy[k] = nil }
        top["policy"] = policy
        return try JSONSerialization.data(withJSONObject: top)
    }

    func testSettingsFromAnOlderVersionKeepWhatItDoesNotSend() throws {
        let coordinator = DeviceIdentity()
        var g = groupWithBoxSettings(coordinator)
        let held = g.policy
        // A coordinator on an older version turns the log off: their phone sends the rest as it
        // knows it, with no box settings.
        var theirs = g.settings
        theirs.policy.keepsLog = false
        let data = try (asOlderVersion(JSONEncoder().encode(theirs)) as NSData).compressed(using: .zlib) as Data
        let sig = try coordinator.signingKey.signature(for: GroupState.settingsInput(group: g.secrets.groupID, signer: 1, version: 1, settings: data))
        XCTAssertTrue(g.apply(settings: .groupSettings(signer: 1, version: 1, settings: data, signature: sig)))
        XCTAssertFalse(g.policy.keepsLog, "their change counts")
        XCTAssertEqual(g.policy.antennaOf, held.antennaOf, "what their version did not send is kept")
        XCTAssertEqual(g.policy.reportsPowerCut, held.reportsPowerCut)
        XCTAssertTrue(g.policy.namesOnBox)
        XCTAssertEqual(g.policy.boxHome, held.boxHome)
        // This version sends every field, empty or not, so emptying one is followed.
        var sender = g
        sender.policy.antennaOf = [:]; sender.policy.reportsPowerCut = []; sender.policy.namesOnBox = false; sender.policy.boxHome = [:]
        sender.settingsVersion = 2
        let frame = try XCTUnwrap(sender.settingsFrame(as: 1, identity: coordinator))
        XCTAssertTrue(g.apply(settings: frame))
        XCTAssertEqual(g.policy, sender.policy, "emptied by a phone that knows them")
        // Every field goes, and the policy reads as before, so an older phone still takes it.
        guard case let .groupSettings(_, _, sent, _) = frame else { return XCTFail("not a settings frame") }
        let json = try XCTUnwrap(GroupState.settingsJSON(sent))
        XCTAssertEqual(GroupState.StoredPolicy.fields(in: json), ["useDistance", "profiles", "profileOf", "keepsLog", "antennaOf", "reportsPowerCut", "namesOnBox", "boxHome"])
        XCTAssertEqual(try JSONDecoder().decode(GroupSettings.self, from: json).policy, sender.policy)
    }

    func testAKeyUpdateFromAnOlderFirstCoordinatorKeepsWhatItDoesNotSend() throws {
        let coordinator = DeviceIdentity(), me = DeviceIdentity()
        let current = groupWithBoxSettings(coordinator, me: me)
        // The first coordinator, on an older version, removed someone and turned the log off.
        var theirs = current
        theirs.remove(4)
        theirs.policy.keepsLog = false
        theirs.settingsVersion = 1
        theirs.settingsSigner = 1
        let plain = try (asOlderVersion(JSONEncoder().encode(theirs)) as NSData).compressed(using: .zlib) as Data
        let sealed = try seal(plain, to: me.publicKey, from: coordinator, context: current.secrets.groupID)
        let update = try Joining.openUpdate(Joining.Welcome(groupID: current.secrets.groupID, memberNumber: 2, sealed: sealed), current: current, me: me)
        XCTAssertEqual(update.secrets, theirs.secrets)
        XCTAssertFalse(update.policy.keepsLog)
        XCTAssertEqual(update.policy.antennaOf, current.policy.antennaOf, "what their version did not send is kept")
        XCTAssertEqual(update.policy.reportsPowerCut, current.policy.reportsPowerCut)
        XCTAssertTrue(update.policy.namesOnBox)
        XCTAssertEqual(update.policy.boxHome, current.policy.boxHome)
        // From this version, an emptied field stays empty.
        theirs.policy.namesOnBox = false
        let now = try Joining.openUpdate(Joining.update(theirs, for: XCTUnwrap(theirs.member(2)), coordinator: coordinator), current: current, me: me)
        XCTAssertFalse(now.policy.namesOnBox)
    }

    func testOwnChoicesCoverOnlyWhatThePersonChose() {
        var coordinators = Profile.standard
        coordinators.personMayChange = [.sounds, .buttons]
        var own = coordinators
        own.soundsAndSpeech = false
        coordinators.buttonWords["red"] = "Come now"
        let applied = coordinators.applying(own, chosen: own.differences(from: Profile.standard))
        XCTAssertFalse(applied.soundsAndSpeech)
        XCTAssertEqual(ButtonWords.words(.red, in: applied), "Come now", "the coordinator's later words, untouched by the person")
    }

    func testHidingSettingsWithOneCoordinatorSuggestsASecond() {
        var g = GroupState(name: "Mill Lane", secrets: .random(), members: [
            Member(number: 1, name: "Sam", role: .coordinator, publicKey: Data(count: 32)),
            Member(number: 2, name: "Pat", role: .caller, publicKey: Data(count: 32), unit: 70001),
        ])
        XCTAssertFalse(g.needsSecondCoordinator)
        g.policy.profiles[0].hidesSettings = true
        XCTAssertTrue(g.needsSecondCoordinator)
        g.members.append(Member(number: 3, name: "Jo", role: .coordinator, publicKey: Data(count: 32)))
        XCTAssertFalse(g.needsSecondCoordinator)
    }
}
