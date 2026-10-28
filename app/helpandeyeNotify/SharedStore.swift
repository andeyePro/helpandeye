import Foundation
import helpandeyeCore
import Security

/// Reads the group the app saved, from the keychain group the app and its extensions share. The
/// group is named in Info.plist (`HelpAKeychainGroup`) once the app is signed; until then
/// there is nothing to share: the push keeps its generic text, and home Wi-Fi listens only while
/// the app is open.
enum SharedStore {
    static func group() -> GroupState? { saved()?.group }

    /// This phone's keys, so the local push extension can prove it is this member on the Wi-Fi.
    static func identity() -> DeviceIdentity? { read("identity").flatMap { try? DeviceIdentity(rawRepresentation: $0) } }

    static func saved() -> SavedState? { read("state").flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) } }

    private static func read(_ account: String) -> Data? {
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "HelpAKeychainGroup") as? String, !accessGroup.isEmpty else { return nil }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.andeye.help",
                                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: accessGroup, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}
