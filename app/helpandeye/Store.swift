import Foundation
import helpandeyeCore
import Security

/// Saves the engine's state: the group and request counter in the keychain, marked "this device
/// only" so it is never backed up or synced, because the keychain survives deleting the app and
/// request numbers must never restart while the unit number stays the same; the activity in a
/// protected file, so a request still open when the app is closed is still there when it reopens.
@MainActor final class AppStore: EngineStore {
    private let group: String
    init(group: String = "") { self.group = group }
    func save(_ state: SavedState?) { Store.save(state, group: group) }
    func save(_ activity: Activity) { Store.save(activity, group: group) }
}

enum Store {
    private static let service = "com.andeye.help"

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

    /// On a watch: the owner's keys, from their paired phone (WatchHandover).
    static func handedOverIdentity() -> DeviceIdentity? {
        guard case let .success(raw) = read("handover.identity") else { return nil }
        return try? DeviceIdentity(rawRepresentation: raw)
    }

    @discardableResult
    static func keep(handedOver identity: DeviceIdentity) -> Bool { write("handover.identity", identity.rawRepresentation) }

    /// On a watch whose owner left the group: nothing of theirs is kept.
    static func forgetHandedOver() {
        SecItemDelete(query("handover.identity") as CFDictionary)
        save(nil as SavedState?)
        save(Activity())
    }

    /// `group` is empty for the group this person calls in (kept where it always was), or a tag for
    /// each other group they respond in.
    static func loadState(_ group: String = "") -> SavedState? {
        guard case let .success(data) = read("state" + group) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    @discardableResult
    static func save(_ state: SavedState?, group: String = "") -> Bool {
        guard let state else { SecItemDelete(query("state" + group) as CFDictionary); return true }
        guard let data = try? JSONEncoder().encode(state) else { return false }
        return write("state" + group, data)
    }

    private static func file(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    static func loadActivity(_ group: String = "") -> Activity {
        (try? Data(contentsOf: file("activity\(group).json"))).flatMap { try? JSONDecoder().decode(Activity.self, from: $0) } ?? Activity()
    }

    static func save(_ activity: Activity, group: String = "") {
        try? JSONEncoder().encode(activity).write(to: file("activity\(group).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func forget(group: String) {
        save(nil as SavedState?, group: group)
        try? FileManager.default.removeItem(at: file("activity\(group).json"))
    }

    /// The box's radio use in the last hour, shared by every group (MeshHub).
    static func loadAirtime() -> AirtimeBudget? {
        (try? Data(contentsOf: file("airtime.json"))).flatMap { try? JSONDecoder().decode(AirtimeBudget.self, from: $0) }
    }

    static func save(airtime: AirtimeBudget?) {
        guard let airtime else { return }
        try? JSONEncoder().encode(airtime).write(to: file("airtime.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The other groups this person responds in, by tag.
    static var otherGroups: [String] {
        get { UserDefaults.standard.stringArray(forKey: "groups.other") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "groups.other") }
    }

    /// The Bluetooth code this app set on a box, by the box's Bluetooth identifier.
    static func boxPin(_ id: UUID) -> UInt32? {
        guard case let .success(d) = read("pin-\(id.uuidString)"), d.count == 4 else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    @discardableResult
    static func setBoxPin(_ pin: UInt32, for id: UUID) -> Bool {
        write("pin-\(id.uuidString)", withUnsafeBytes(of: pin) { Data($0) })
    }

    static var boardID: UUID? {
        get { UserDefaults.standard.string(forKey: "board").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "board") }
    }

    /// Shared with the notification extension once the app is signed with a keychain group (named
    /// in Info.plist); unsigned builds keep the app's own keychain.
    private static let accessGroup = (Bundle.main.object(forInfoDictionaryKey: "HelpAKeychainGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }

    private static func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
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
