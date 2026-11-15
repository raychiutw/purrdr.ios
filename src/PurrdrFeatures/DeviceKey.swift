import CryptoKit
import Foundation
import PurrdrCore
import Security
import Synchronization

/// 這支裝置的 SSH 金鑰(Seam 3 平台服務)。所有 OpenSSH 主機共用同一把;第一次用到時才產生。
public protocol DeviceKey: Sendable {
    /// 公鑰(含辨識這支裝置的註解),用來加進主機的 `authorized_keys`。還沒有金鑰就產生。
    func publicKey() throws -> SSHPublicKey
    /// 登入用的私鑰。
    func signingKey() throws -> SSHPrivateKey
}

public enum DeviceKeyError: Error, Equatable {
    /// 這台裝置(例如模擬器)沒有 Secure Enclave。
    case secureEnclaveUnavailable
}

/// Secure Enclave 的介面(正式用 `SystemSecureEnclave`,測試用假實作;模擬器與 `swift test` 沒有 Secure Enclave)。
public protocol SecureEnclaveAPI: Sendable {
    var isAvailable: Bool { get }
    /// 在 Secure Enclave 產生 P-256 金鑰，回傳它的 `dataRepresentation`:
    /// 只有這支裝置的 Secure Enclave 解得開的密文，私鑰本身不離開 Secure Enclave。
    func createKey() throws -> Data
    func key(from data: Data) throws -> SSHPrivateKey
}

/// 系統的 Secure Enclave(CryptoKit)。
public struct SystemSecureEnclave: SecureEnclaveAPI {
    public init() {}

    public var isAvailable: Bool { SecureEnclave.isAvailable }

    public func createKey() throws -> Data {
        // 解鎖時、僅此裝置可用;不要求 Face ID(背景輪詢與重新連線時不能跳出驗證)。
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error)
        else { throw error!.takeRetainedValue() as any Error }
        return try SecureEnclave.P256.Signing.PrivateKey(accessControl: access).dataRepresentation
    }

    public func key(from data: Data) throws -> SSHPrivateKey {
        SSHPrivateKey(secureEnclave: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data))
    }
}

/// Secure Enclave 裡的裝置金鑰。金鑰的 `dataRepresentation` 存 Keychain(解鎖時、僅此裝置、不同步);
/// 還原到其他裝置也解不開，所以私鑰永遠只在這支裝置。
public final class SecureEnclaveDeviceKey: DeviceKey {
    private let keychain: any KeychainAPI
    private let enclave: any SecureEnclaveAPI
    private let comment: String
    private let service: String
    private let cached = Mutex<SSHPrivateKey?>(nil)

    /// - Parameter comment: 公鑰的註解，讓主機上的 `authorized_keys` 認得是哪支裝置。
    public init(
        keychain: any KeychainAPI = SystemKeychain(), enclave: any SecureEnclaveAPI = SystemSecureEnclave(),
        comment: String, service: String = "com.raychiu.purrdr.device-key"
    ) {
        self.keychain = keychain
        self.enclave = enclave
        self.comment = comment
        self.service = service
    }

    public func publicKey() throws -> SSHPublicKey {
        try signingKey().publicKey.withComment(comment)
    }

    public func signingKey() throws -> SSHPrivateKey {
        try cached.withLock { cached in
            if let cached { return cached }
            guard enclave.isAvailable else { throw DeviceKeyError.secureEnclaveUnavailable }
            let key = try enclave.key(from: try storedKey() ?? createAndStore())
            cached = key
            return key
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "secure-enclave-p256",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func storedKey() throws -> Data? {
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    private func createAndStore() throws -> Data {
        let data = try enclave.createKey()
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Purrdr device key"
        let status = keychain.add(attributes)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return data
    }
}

/// 軟體 P-256 金鑰，只存在記憶體。UI 測試與單元測試用(模擬器沒有 Secure Enclave)。
public final class EphemeralDeviceKey: DeviceKey {
    private let key = P256.Signing.PrivateKey()
    private let comment: String

    public init(comment: String = "purrdr@demo") {
        self.comment = comment
    }

    public func publicKey() throws -> SSHPublicKey { try signingKey().publicKey.withComment(comment) }

    public func signingKey() throws -> SSHPrivateKey { SSHPrivateKey(p256: key) }
}
