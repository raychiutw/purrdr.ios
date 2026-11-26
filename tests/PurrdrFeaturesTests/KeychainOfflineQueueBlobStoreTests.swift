#if canImport(Security)
import Foundation
import PurrdrAgentFeatures
import Security
import Testing

/// 離線佇列的 Keychain adapter(#575):用假的 SecItem 介面驗證送給 Keychain 的屬性。只在 Apple 平台編譯與執行。
@Suite("離線佇列的 Keychain 儲存")
struct KeychainOfflineQueueBlobStoreTests {
    final class FakeKeychain: OfflineQueueKeychainAPI, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [String: Data] = [:]
        private(set) var addedAttributes: [[String: Any]] = []
        private(set) var deleteQueries: [[String: Any]] = []

        func add(_ attributes: [String: Any]) -> OSStatus {
            lock.withLock {
                addedAttributes.append(attributes)
                items[attributes[kSecAttrAccount as String] as? String ?? ""] = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            }
        }

        func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
            lock.withLock {
                let account = query[kSecAttrAccount as String] as? String ?? ""
                guard items[account] != nil else { return errSecItemNotFound }
                items[account] = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            }
        }

        func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
            lock.withLock {
                guard let data = items[query[kSecAttrAccount as String] as? String ?? ""] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data as NSData)
            }
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            lock.withLock {
                deleteQueries.append(query)
                if let account = query[kSecAttrAccount as String] as? String {
                    items[account] = nil
                } else {
                    items = [:]
                }
                return errSecSuccess
            }
        }
    }

    @Test("新增的項目：service、account、僅此裝置、首次解鎖後可讀、不同步")
    func addsWithDeviceOnlyAttributes() throws {
        let keychain = FakeKeychain()
        let store = KeychainOfflineQueueBlobStore(keychain: keychain)

        try store.write(Data("x".utf8), account: "demo")

        let attributes = try #require(keychain.addedAttributes.first)
        #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attributes[kSecAttrService as String] as? String == "purrdr.offlineQueue")
        #expect(attributes[kSecAttrAccount as String] as? String == "demo")
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test("已有項目：原地更新，不重複新增")
    func updatesExistingItem() throws {
        let keychain = FakeKeychain()
        let store = KeychainOfflineQueueBlobStore(keychain: keychain)
        try store.write(Data("1".utf8), account: "demo")

        try store.write(Data("2".utf8), account: "demo")

        #expect(keychain.addedAttributes.count == 1)
        #expect(store.read(account: "demo") == Data("2".utf8))
    }

    @Test("讀不到：回 nil;刪除單一項目與全部清除")
    func readDeleteAndDeleteAll() throws {
        let keychain = FakeKeychain()
        let store = KeychainOfflineQueueBlobStore(keychain: keychain)
        #expect(store.read(account: "none") == nil)
        try store.write(Data("a".utf8), account: "a")
        try store.write(Data("b".utf8), account: "b")

        store.delete(account: "a")
        #expect(store.read(account: "a") == nil)
        #expect(store.read(account: "b") != nil)
    }
}
#endif
