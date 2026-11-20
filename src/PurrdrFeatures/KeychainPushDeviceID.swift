import Foundation
import Security

/// 「通知裝置」用的這支裝置 id(#266):隨機 UUID(小寫),存在 Keychain(只在這支裝置、不進 iCloud 鑰匙圈)。
///
/// 重裝 app 仍沿用同一個 id,後台才不會把同一支裝置列成兩台。
public enum KeychainPushDeviceID {
    private static let account = "push.deviceUUID"

    /// 讀出 id;沒有就產生並存起來。Keychain 讀寫失敗時回這次啟動用的新 id(下次再試著存)。
    public static func load(service: String = "com.raychiu.purrdr") -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
           let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) {
            return id.uuidString.lowercased()
        }
        let id = UUID().uuidString.lowercased()
        var item = query
        item[kSecValueData as String] = Data(id.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        SecItemAdd(item as CFDictionary, nil)
        return id
    }
}
