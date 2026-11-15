import Foundation
import PurrdrCore
import Security

/// Keychain 的 SecItem 介面(Seam 3 平台服務):正式用 `SystemKeychain`,測試用假實作。
public protocol KeychainAPI: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func delete(_ query: [String: Any]) -> OSStatus
}

/// 系統 Keychain。
public struct SystemKeychain: KeychainAPI {
    public init() {}

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// 讓 Keychain 錯誤在畫面上有可讀的說明(`KeychainError` 定義在 `KeychainTokenStore.swift`)。
extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain error: \(detail)"
    }
}

/// 主機設定與 host key pin 存 Keychain:一台主機一個 generic password 項目，
/// 可存取等級「解鎖時、僅此裝置」,不經 iCloud 同步(行為規格 §8.1)。
@MainActor
public final class KeychainHostStore: HostStore {
    private let keychain: any KeychainAPI
    private let service: String

    public init(keychain: any KeychainAPI = SystemKeychain(), service: String = "com.raychiu.purrdr.host") {
        self.keychain = keychain
        self.service = service
    }

    public func loadHosts() throws -> [HostConfiguration] {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let items = result as? [[String: Any]] ?? []
        let decoder = JSONDecoder()
        // 讀不懂的項目(之後版本的格式)略過，不讓整個主機清單讀不出來。
        return items.compactMap { item in
            (item[kSecValueData as String] as? Data).flatMap { try? decoder.decode(HostConfiguration.self, from: $0) }
        }
    }

    public func save(_ host: HostConfiguration) throws {
        let data = try JSONEncoder().encode(host)
        var attributes = itemQuery(host.id)
        attributes[kSecValueData as String] = data
        // 可存取等級只能在新增項目時設定。
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Purrdr host"
        let status = keychain.add(attributes)
        if status == errSecDuplicateItem {
            let updated = keychain.update(itemQuery(host.id), [kSecValueData as String: data])
            guard updated == errSecSuccess else { throw KeychainError(status: updated) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ id: UUID) throws {
        let status = keychain.delete(itemQuery(id))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            // macOS 也用 data protection keychain,行為與 iOS 相同。
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func itemQuery(_ id: UUID) -> [String: Any] {
        var query = baseQuery
        query[kSecAttrAccount as String] = id.uuidString
        return query
    }
}
