import Foundation
import PurrdrCore
import Security
import Synchronization

/// OpenSSH 主機的祕密：密碼，或匯入的私鑰(原文)與 passphrase。永不同步(GLOSSARY「主機同步」)。
public enum HostSecret: Sendable, Hashable, Codable {
    case password(String)
    /// OpenSSH 格式的私鑰原文，與 passphrase(沒有為 `nil`)。
    case privateKey(String, passphrase: String?)
}

/// 主機祕密的儲存(Seam 3 平台服務)。撥號時在背景讀，所以不綁 main actor。
public protocol HostSecretStore: Sendable {
    func secret(for host: UUID) throws -> HostSecret?
    /// `nil` = 刪除。
    func setSecret(_ secret: HostSecret?, for host: UUID) throws
}

/// 祕密存 Keychain:每台主機一個 generic password 項目，與主機設定分開(主機同步只帶設定)。
/// 可存取等級「解鎖時、僅此裝置」,不經 iCloud 同步(行為規格 §8.1)。
public struct KeychainHostSecretStore: HostSecretStore {
    private let keychain: any KeychainAPI
    private let service: String

    public init(keychain: any KeychainAPI = SystemKeychain(), service: String = "com.raychiu.purrdr.host-secret") {
        self.keychain = keychain
        self.service = service
    }

    public func secret(for host: UUID) throws -> HostSecret? {
        var query = itemQuery(host)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(HostSecret.self, from: data)
    }

    public func setSecret(_ secret: HostSecret?, for host: UUID) throws {
        guard let secret else {
            let status = keychain.delete(itemQuery(host))
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = try JSONEncoder().encode(secret)
        var attributes = itemQuery(host)
        attributes[kSecValueData as String] = data
        // 可存取等級只能在新增項目時設定。
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Purrdr host secret"
        let status = keychain.add(attributes)
        if status == errSecDuplicateItem {
            let updated = keychain.update(itemQuery(host), [kSecValueData as String: data])
            guard updated == errSecSuccess else { throw KeychainError(status: updated) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func itemQuery(_ host: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.uuidString,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// 只存在記憶體的祕密儲存。UI 測試用(`-uiTesting` 不碰 Keychain)。
public final class EphemeralHostSecretStore: HostSecretStore {
    private let secrets = Mutex<[UUID: HostSecret]>([:])

    public init() {}

    public func secret(for host: UUID) throws -> HostSecret? { secrets.withLock { $0[host] } }

    public func setSecret(_ secret: HostSecret?, for host: UUID) throws { secrets.withLock { $0[host] = secret } }
}
