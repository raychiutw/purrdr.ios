import Crypto
import Foundation
import PurrdrCore
import PurrdrFeatures
import Security
import Testing

/// 假的 Secure Enclave:用軟體 P-256,`dataRepresentation` 是私鑰本身(只在測試裡)。記錄產生次數。
final class FakeSecureEnclave: SecureEnclaveAPI, @unchecked Sendable {
    var isAvailable = true
    private(set) var created = 0

    func createKey() throws -> Data {
        created += 1
        return P256.Signing.PrivateKey().rawRepresentation
    }

    func key(from data: Data) throws -> SSHPrivateKey {
        SSHPrivateKey(p256: try P256.Signing.PrivateKey(rawRepresentation: data))
    }
}

@Suite("主機祕密存 Keychain")
struct HostSecretKeychainTests {
    let host = UUID()

    @Test("祕密存成「解鎖時、僅此裝置」且不同步的項目，與主機設定不同 service")
    func storedOnlyOnThisDevice() throws {
        let keychain = FakeKeychain()
        let store = KeychainHostSecretStore(keychain: keychain)

        try store.setSecret(.password("hunter2"), for: host)

        let attributes = try #require(keychain.addedAttributes.first)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrService as String] as? String == "com.raychiu.purrdr.host-secret")
    }

    @Test("存了讀得回來;換成金鑰是更新;設成 nil 就刪除")
    func roundTrip() throws {
        let store = KeychainHostSecretStore(keychain: FakeKeychain())
        #expect(try store.secret(for: host) == nil)

        try store.setSecret(.password("hunter2"), for: host)
        #expect(try store.secret(for: host) == .password("hunter2"))
        try store.setSecret(.privateKey("-----BEGIN…", passphrase: "pw"), for: host)
        #expect(try store.secret(for: host) == .privateKey("-----BEGIN…", passphrase: "pw"))

        try store.setSecret(nil, for: host)
        #expect(try store.secret(for: host) == nil)
    }
}

@Suite("這支裝置的金鑰(Secure Enclave)")
struct SecureEnclaveDeviceKeyTests {
    @Test("第一次取公鑰才產生金鑰;金鑰的 dataRepresentation 存成「解鎖時、僅此裝置」的 Keychain 項目")
    func createsOnceAndStoresOnThisDevice() throws {
        let keychain = FakeKeychain()
        let enclave = FakeSecureEnclave()
        let key = SecureEnclaveDeviceKey(keychain: keychain, enclave: enclave, comment: "purrdr@iPhone")
        #expect(enclave.created == 0)

        let first = try key.publicKey()
        let again = try key.publicKey()

        #expect(enclave.created == 1)
        #expect(first == again)
        #expect(first.openSSH.hasPrefix("ecdsa-sha2-nistp256 "))
        #expect(first.openSSH.hasSuffix(" purrdr@iPhone"))
        let attributes = try #require(keychain.addedAttributes.first)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test("重開 app 後讀回同一把金鑰，不會換掉已加到主機的公鑰")
    func reloadsSameKey() throws {
        let keychain = FakeKeychain()
        let enclave = FakeSecureEnclave()
        let before = try SecureEnclaveDeviceKey(keychain: keychain, enclave: enclave, comment: "c").publicKey()

        let after = SecureEnclaveDeviceKey(keychain: keychain, enclave: enclave, comment: "c")

        #expect(try after.publicKey() == before)
        #expect(try after.signingKey().publicKey.withComment("c") == before)
        #expect(enclave.created == 1)
    }

    @Test("沒有 Secure Enclave(模擬器):說明不可用，不改用軟體金鑰")
    func unavailable() {
        let enclave = FakeSecureEnclave()
        enclave.isAvailable = false
        let key = SecureEnclaveDeviceKey(keychain: FakeKeychain(), enclave: enclave, comment: "c")

        #expect(throws: DeviceKeyError.secureEnclaveUnavailable) { try key.publicKey() }
        #expect(enclave.created == 0)
    }
}
