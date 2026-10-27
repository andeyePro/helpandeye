import Foundation
import HelpAndICore
import Security

/// Everything the app keeps between launches. Keys and group secrets go in the keychain, marked
/// "this device only" so they are never backed up or synced; the rest in user defaults.
struct SavedState: Codable {
    var group: GroupState
    var me: UInt16
}

enum Store {
    private static let service = "org.andeye.helpandi"

    static func identity() -> DeviceIdentity {
        if let raw = read("identity"), let id = try? DeviceIdentity(rawRepresentation: raw) { return id }
        let id = DeviceIdentity()
        write("identity", id.privateKey.rawRepresentation)
        return id
    }

    static func loadState() -> SavedState? {
        read("state").flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
    }

    static func save(_ state: SavedState?) {
        guard let state, let data = try? JSONEncoder().encode(state) else { delete("state"); return }
        write("state", data)
    }

    static var boardID: UUID? {
        get { UserDefaults.standard.string(forKey: "board").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "board") }
    }

    /// Request numbers only ever go up, so a responder never mistakes a new call for an old one.
    static func nextRequestNumber() -> UInt16 {
        let n = UInt16(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "request") + 1)
        UserDefaults.standard.set(Int(n), forKey: "request")
        return n
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private static func write(_ account: String, _ data: Data) {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
