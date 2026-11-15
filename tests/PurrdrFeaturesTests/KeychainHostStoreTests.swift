import Foundation
import PurrdrCore
import PurrdrFeatures
import Security
import Testing

/// Keychain 的假實作(Seam 3):依 service + account 存資料，記錄每次新增時的屬性。
final class FakeKeychain: KeychainAPI, @unchecked Sendable {
    var items: [String: Data] = [:]
    var addedAttributes: [[String: Any]] = []
    var addStatus: OSStatus = errSecSuccess

    func add(_ attributes: [String: Any]) -> OSStatus {
        guard addStatus == errSecSuccess else { return addStatus }
        let account = attributes[kSecAttrAccount as String] as! String
        guard items[account] == nil else { return errSecDuplicateItem }
        addedAttributes.append(attributes)
        items[account] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        let account = query[kSecAttrAccount as String] as! String
        guard items[account] != nil else { return errSecItemNotFound }
        items[account] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        guard !items.isEmpty else { return (errSecItemNotFound, nil) }
        let all = items.sorted { $0.key < $1.key }.map { [kSecValueData as String: $0.value] as NSDictionary }
        return (errSecSuccess, all as NSArray)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let account = query[kSecAttrAccount as String] as! String
        return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }
}

@MainActor
@Suite("主機存 Keychain")
struct KeychainHostStoreTests {
    static let host = HostConfiguration(
        name: "Studio", endpoint: SSHEndpoint(host: "ray-mac-mini", username: "demo"),
        herdr: HerdrInstallation(session: "work"), operatingSystem: .macOS,
        hostKeyPin: HostKeyFingerprint(stored: "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww"))

    @Test("主機與 pin 存成「解鎖時、僅此裝置」且不同步的 Keychain 項目")
    func storesOnlyOnThisDeviceWhenUnlocked() throws {
        let keychain = FakeKeychain()
        let store = KeychainHostStore(keychain: keychain)

        try store.save(Self.host)

        let attributes = try #require(keychain.addedAttributes.first)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
    }

    @Test("存了讀得回來;再存一次是更新，不是多一筆;刪除後就不在了")
    func roundTrip() throws {
        let store = KeychainHostStore(keychain: FakeKeychain())
        #expect(try store.loadHosts().isEmpty)

        try store.save(Self.host)
        var renamed = Self.host
        renamed.name = "Studio Mac"
        try store.save(renamed)
        #expect(try store.loadHosts() == [renamed])

        try store.delete(Self.host.id)
        #expect(try store.loadHosts().isEmpty)
    }

    @Test("Keychain 拒絕寫入時丟出錯誤(畫面要留在編輯器說明)")
    func writeFailureThrows() {
        let keychain = FakeKeychain()
        keychain.addStatus = errSecMissingEntitlement
        let store = KeychainHostStore(keychain: keychain)

        #expect(throws: KeychainError.self) { try store.save(Self.host) }
    }
}
