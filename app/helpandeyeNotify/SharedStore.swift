import Foundation
import helpandeyeCore
import Security

/// Reads the group the app saved, from the keychain group the app and its extensions share. The
/// group is named in Info.plist (`HelpAKeychainGroup`) once the app is signed; until then
/// there is nothing to share: the push keeps its generic text, and home Wi-Fi listens only while
/// the app is open.
enum SharedStore {
    static func group() -> GroupState? { saved()?.group }

    static func saved() -> SavedState? {
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "HelpAKeychainGroup") as? String, !accessGroup.isEmpty else { return nil }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.andeye.help",
                                kSecAttrAccount as String: "state", kSecAttrAccessGroup as String: accessGroup, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return nil }
        return saved
    }
}
