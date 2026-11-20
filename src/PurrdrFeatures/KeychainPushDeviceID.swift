import Foundation
import PurrdrCore
import Security

/// 這支裝置的推播 id 存在 Keychain(只在這支裝置、不進 iCloud 鑰匙圈),重裝 app 仍相同。
///
/// 0.45 以前存在 UserDefaults 的 id 第一次讀取時搬進來沿用：換新 id 會讓主機上留下舊的 `push-<id>`。
public struct KeychainPushDeviceID {
    /// 0.45 以前存 id 的 UserDefaults key。
    public static let legacyDefaultsKey = "push.deviceID"
    static let account = "push.deviceID"

    let keychain: any KeychainAPI
    let service: String
    let legacyDefaults: UserDefaults

    public init(
        keychain: any KeychainAPI = SystemKeychain(), service: String = "com.raychiu.purrdr", legacyDefaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.service = service
        self.legacyDefaults = legacyDefaults
    }

    /// 讀出 id;Keychain 裡沒有(`errSecItemNotFound`)才搬舊 id 或產生新的。其他讀寫錯誤丟出，稍後再試。
    public func load() throws -> PushDeviceID {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(lookup)
        switch status {
        case errSecSuccess:
            if let data = result as? Data, let id = PushDeviceID(rawValue: String(decoding: data, as: UTF8.self)) { return id }
        case errSecItemNotFound:
            break
        default:
            throw PushDeviceIDError.unreadable(status: status)
        }
        let id = legacyDefaults.string(forKey: Self.legacyDefaultsKey).flatMap(PushDeviceID.init(rawValue:)) ?? .generate()
        try save(id)
        legacyDefaults.removeObject(forKey: Self.legacyDefaultsKey)
        return id
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: Self.account]
    }

    private func save(_ id: PushDeviceID) throws {
        _ = keychain.delete(query)
        var item = query
        item[kSecValueData as String] = Data(id.rawValue.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = keychain.add(item)
        guard status == errSecSuccess else { throw PushDeviceIDError.unsaved(status: status) }
    }
}
