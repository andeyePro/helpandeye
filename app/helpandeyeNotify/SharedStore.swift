import Foundation
import helpandeyeCore
import Security

/// Reads the group the app saved, from the keychain group the app and this extension share. The
/// group is named in Info.plist (`HelpAndIKeychainGroup`) once the app is signed; until then
/// there is nothing to share and the push keeps its generic text.
enum SharedStore {
    static func group() -> GroupState? {
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "HelpAndIKeychainGroup") as? String, !accessGroup.isEmpty else { return nil }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.andeye.help",
                                kSecAttrAccount as String: "state", kSecAttrAccessGroup as String: accessGroup, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return nil }
        return saved.group
    }
}
