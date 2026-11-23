import Foundation
import PurrdrCore
import Security

/// 把後台的登入資料存在 Keychain(只在這支裝置、第一次解鎖後可讀，不進 iCloud 鑰匙圈)。#406
///
/// 三個項目:更新權杖、存取權杖(含到期時間)、會員快照。
/// **寫入先寫新的**:已有項目就原地更新(`SecItemUpdate`)、沒有才新增,不會先刪再寫,所以寫入失敗時舊值還在。
public struct KeychainTokenStore: TokenStore {
    private let keychain: any KeychainAPI
    private let service: String

    static let refreshAccount = "backend.refreshToken"
    static let accessAccount = "backend.accessToken"
    static let memberAccount = "backend.member"

    public init(keychain: any KeychainAPI = SystemKeychain(), service: String = "com.raychiu.purrdr") {
        self.keychain = keychain
        self.service = service
    }

    public func refreshToken() throws -> String? {
        try read(Self.refreshAccount).map { String(decoding: $0, as: UTF8.self) }
    }

    public func setRefreshToken(_ token: String?) throws {
        try write(token.map { Data($0.utf8) }, account: Self.refreshAccount)
    }

    public func accessToken() throws -> StoredAccessToken? {
        guard let data = try read(Self.accessAccount) else { return nil }
        // 讀不懂的存取權杖當作沒有(下一次用更新權杖換新的),不是登入失效。
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return StoredAccessToken(token: stored.token, expiresAt: Date(timeIntervalSince1970: stored.expiresAt))
    }

    public func setAccessToken(_ token: StoredAccessToken?) throws {
        let data = try token.map {
            try JSONEncoder().encode(Stored(token: $0.token, expiresAt: $0.expiresAt.timeIntervalSince1970))
        }
        try write(data, account: Self.accessAccount)
    }

    public func memberSnapshot() throws -> Data? {
        try read(Self.memberAccount)
    }

    public func setMemberSnapshot(_ snapshot: Data?) throws {
        try write(snapshot, account: Self.memberAccount)
    }

    private struct Stored: Codable {
        var token: String
        var expiresAt: TimeInterval
    }

    private func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    /// `nil` 是刪除;有值時原地更新或新增(不先刪)。
    private func write(_ data: Data?, account: String) throws {
        let query = baseQuery(account)
        guard let data else {
            let status = keychain.delete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let updateStatus = keychain.update(query, [kSecValueData as String: data])
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = keychain.add(item)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct KeychainError: Error, Equatable {
    public var status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}
