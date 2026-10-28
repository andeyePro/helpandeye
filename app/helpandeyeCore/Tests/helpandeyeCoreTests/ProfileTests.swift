import XCTest
@testable import helpandeyeCore

final class ProfileTests: XCTestCase {
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
        guard let frame = g.settingsFrame(as: 1, identity: coordinator) else { return XCTFail("settings too big for a frame") }
        XCTAssertEqual(HelpFrame(frame.encoded()), frame)
        var copy = g
        copy.policy = .init()
        copy.settingsVersion = 0
        XCTAssertTrue(copy.apply(settings: frame))
        XCTAssertEqual(copy.policy, g.policy)
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
