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
        return String(localized: "Couldn’t read or save sign-in details: \(detail)")
    }
}

/// 主機設定與 host key pin 存 Keychain:一台主機一個 generic password 項目，
/// 可存取等級「解鎖時、僅此裝置」,不經 iCloud 同步(行為規格 §8.1)。
@MainActor
public final class KeychainHostStore: HostStore {
    private let keychain: any KeychainAPI
    private let service: String
    private let diagnostics: DiagnosticLog

    /// - Parameter diagnostics: 讀不懂的項目記在這裡(不給使用者看)。
    public init(
        keychain: any KeychainAPI = SystemKeychain(), service: String = "com.raychiu.purrdr.host",
        diagnostics: DiagnosticLog = .system(category: "hosts")
    ) {
        self.keychain = keychain
        self.service = service
        self.diagnostics = diagnostics
    }

    public func loadHosts() throws -> [HostConfiguration] {
        let outcome = try Self.readHosts(keychain: keychain, service: service)
        for problem in outcome.problems { diagnostics.error(problem) }
        return outcome.hosts
    }

    /// 不在主執行緒讀 Keychain(#590):冷啟動時第一個 frame 不等 SecItem 讀取(解鎖後第一次讀可能要幾十毫秒以上)。
    public func loadHostsInBackground() async throws -> [HostConfiguration] {
        let keychain = keychain, service = service
        let outcome = try await Self.readHostsOffMain(keychain: keychain, service: service)
        for problem in outcome.problems { diagnostics.error(problem) }
        return outcome.hosts
    }

    private struct ReadOutcome: Sendable {
        var hosts: [HostConfiguration]
        /// 讀不懂的項目(不給使用者看,由呼叫端記進診斷記錄)。
        var problems: [String]
    }

    @concurrent
    private static func readHostsOffMain(keychain: any KeychainAPI, service: String) async throws -> ReadOutcome {
        try readHosts(keychain: keychain, service: service)
    }

    private nonisolated static func readHosts(keychain: any KeychainAPI, service: String) throws -> ReadOutcome {
        var query = baseQuery(service: service)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return ReadOutcome(hosts: [], problems: []) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let items = result as? [[String: Any]] ?? []
        let decoder = JSONDecoder()
        var problems: [String] = []
        // 讀不懂的項目(之後版本的格式、缺欄位的舊資料)不讓整個清單讀不出來：記下來，項目留著給之後的版本讀。
        let hosts = items.compactMap { item -> HostConfiguration? in
            guard let data = item[kSecValueData as String] as? Data else { return nil }
            do {
                return try decoder.decode(HostConfiguration.self, from: data)
            } catch {
                let account = item[kSecAttrAccount as String] as? String ?? "unknown"
                problems.append("Couldn’t read the saved host \(account); it isn’t shown: \(error)")
                return nil
            }
        }
        return ReadOutcome(hosts: hosts, problems: problems)
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

    private var baseQuery: [String: Any] { Self.baseQuery(service: service) }

    private nonisolated static func baseQuery(service: String) -> [String: Any] {
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
