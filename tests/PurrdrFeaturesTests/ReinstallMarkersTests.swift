import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import Security
import Testing

/// 重裝清理接上真實的 Keychain 項目與 UserDefaults(#580),用 service 分區的假 Keychain 與獨立的 UserDefaults suite。
@Suite("重裝清理的標記與清除")
struct ReinstallMarkersTests {
    final class ServiceKeychain: KeychainAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        private(set) var addedAttributes: [[String: Any]] = []

        private static func key(_ query: [String: Any]) -> String {
            "\(query[kSecAttrService as String] as! String)/\(query[kSecAttrAccount as String] as? String ?? "*")"
        }

        func seed(service: String, account: String) { lock.withLock { items["\(service)/\(account)"] = Data([7]) } }
        func has(service: String) -> Bool { lock.withLock { items.keys.contains { $0.hasPrefix(service + "/") } } }

        func add(_ attributes: [String: Any]) -> OSStatus {
            lock.withLock {
                let key = Self.key(attributes)
                guard items[key] == nil else { return errSecDuplicateItem }
                items[key] = attributes[kSecValueData as String] as? Data
                addedAttributes.append(attributes)
                return errSecSuccess
            }
        }

        func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus { errSecItemNotFound }

        func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
            lock.withLock {
                guard let data = items[Self.key(query)] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data as NSData)
            }
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            lock.withLock {
                let service = query[kSecAttrService as String] as! String
                let doomed = items.keys.filter { $0.hasPrefix(service + "/") }
                for key in doomed { items[key] = nil }
                return doomed.isEmpty ? errSecItemNotFound : errSecSuccess
            }
        }
    }

    static func freshDefaults() -> UserDefaults {
        let name = "ReinstallMarkersTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func seedAppItems(_ keychain: ServiceKeychain) {
        for service in AppKeychainPurge.services { keychain.seed(service: service, account: "item") }
    }

    @Test("清除的 service 涵蓋主機、主機密碼、裝置金鑰、權杖與離線佇列,且不含標記")
    func purgeServices() {
        #expect(AppKeychainPurge.services.contains("com.raychiu.purrdr.host"))
        #expect(AppKeychainPurge.services.contains(KeychainOfflineQueueBlobStore.service))
        #expect(!AppKeychainPurge.services.contains(KeychainInstallMarker.service))
    }

    @Test("升級:兩邊都沒標記,Keychain 的主機與密碼原封不動,只補標記")
    func upgradeKeepsHostsAndPasswords() {
        let keychain = ServiceKeychain()
        Self.seedAppItems(keychain)
        let defaults = Self.freshDefaults()

        let outcome = ReinstallGuard.system(defaults: defaults, keychain: keychain).run()

        #expect(outcome == .firstLaunch)
        for service in AppKeychainPurge.services { #expect(keychain.has(service: service)) }
        #expect(UserDefaultsInstallMarker(defaults: defaults).isMarked)
        #expect(KeychainInstallMarker(keychain: keychain).isMarked)
    }

    @Test("全新安裝:沒有任何項目,只補標記")
    func freshInstall() {
        let keychain = ServiceKeychain()
        let defaults = Self.freshDefaults()

        #expect(ReinstallGuard.system(defaults: defaults, keychain: keychain).run() == .firstLaunch)
        #expect(KeychainInstallMarker(keychain: keychain).isMarked)
    }

    @Test("重裝:Keychain 有標記、UserDefaults 沒有,清掉所有 App 項目後重寫兩個標記")
    func reinstallPurgesEverything() {
        let keychain = ServiceKeychain()
        KeychainInstallMarker(keychain: keychain).mark()
        Self.seedAppItems(keychain)
        let defaults = Self.freshDefaults()

        let outcome = ReinstallGuard.system(defaults: defaults, keychain: keychain).run()

        #expect(outcome == .reinstalled)
        for service in AppKeychainPurge.services { #expect(!keychain.has(service: service)) }
        #expect(UserDefaultsInstallMarker(defaults: defaults).isMarked)
        #expect(KeychainInstallMarker(keychain: keychain).isMarked)
    }

    @Test("第二次啟動:兩邊都有標記,不清")
    func secondLaunch() {
        let keychain = ServiceKeychain()
        let defaults = Self.freshDefaults()
        ReinstallGuard.system(defaults: defaults, keychain: keychain).run()
        Self.seedAppItems(keychain)

        #expect(ReinstallGuard.system(defaults: defaults, keychain: keychain).run() == .normal)
        for service in AppKeychainPurge.services { #expect(keychain.has(service: service)) }
    }

    @Test("Keychain 標記是「第一次解鎖後、僅此裝置」且不同步")
    func keychainMarkerAttributes() throws {
        let keychain = ServiceKeychain()

        KeychainInstallMarker(keychain: keychain).mark()

        let attributes = try #require(keychain.addedAttributes.first)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
    }
}
