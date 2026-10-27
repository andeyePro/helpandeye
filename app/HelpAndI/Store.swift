import Foundation
import HelpAndICore
import Security

/// The group, this phone's place in it, and its request counter. Kept in the keychain, marked
/// "this device only" so it is never backed up or synced. The counter lives here rather than in
/// user defaults because the keychain survives deleting the app: request numbers must never
/// restart while the unit number stays the same.
struct SavedState: Codable {
    var group: GroupState
    var me: UInt16
    var lastRequest: UInt16 = 0
    var checkIn: CheckInSchedule?
    var checkInSince: Date?
}

/// What is happening now: open calls, the responder's list, the rota. Saved to a file so that a
/// request still open when the app is closed is still there, unacknowledged, when it reopens.
struct Activity: Codable {
    var outgoing: [OutgoingRequest] = []
    var inbox = ResponderInbox()
    var rota = Rota()
    var lastAnswered: [UInt16: Date] = [:]
    var greens: [Date] = []
    /// This phone's own radio use in the last hour (IR 2030), kept across relaunches and re-pairing.
    var airtime: AirtimeBudget?
    /// Other callers' check-ins, so this phone notices a missed one too.
    var checkInWatch = CheckInWatch()
    /// Members' boxes, by member number, for direct messages over the mesh.
    var boardKeys: [UInt16: Data] = [:]
}

enum Store {
    private static let service = "org.andeye.helpandi"

    /// The phone's keys, made the first time and never replaced unless they are truly missing. If
    /// the keychain cannot be read (before the phone's first unlock after a restart), a key is used
    /// for this launch only and not saved.
    static func identity() -> DeviceIdentity {
        switch read("identity") {
        case let .success(raw):
            if let id = try? DeviceIdentity(rawRepresentation: raw) { return id }
            fallthrough
        case .failure(errSecItemNotFound):
            let id = DeviceIdentity()
            _ = write("identity", id.rawRepresentation)
            return id
        case .failure:
            return DeviceIdentity()
        }
    }

    static func loadState() -> SavedState? {
        guard case let .success(data) = read("state") else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    @discardableResult
    static func save(_ state: SavedState?) -> Bool {
        guard let state else { SecItemDelete(query("state") as CFDictionary); return true }
        guard let data = try? JSONEncoder().encode(state) else { return false }
        return write("state", data)
    }

    private static var activityURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity.json")
    }

    static func loadActivity() -> Activity {
        (try? Data(contentsOf: activityURL)).flatMap { try? JSONDecoder().decode(Activity.self, from: $0) } ?? Activity()
    }

    static func save(_ activity: Activity) {
        try? JSONEncoder().encode(activity).write(to: activityURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static var boardID: UUID? {
        get { UserDefaults.standard.string(forKey: "board").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "board") }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> Result<Data, OSStatus> {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return .failure(status == errSecSuccess ? errSecDecode : status) }
        return .success(data)
    }

    /// Updates in place, and adds only if there was nothing to update, so a failed write never
    /// deletes what was there.
    private static func write(_ account: String, _ data: Data) -> Bool {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

extension OSStatus: @retroactive Error {}
