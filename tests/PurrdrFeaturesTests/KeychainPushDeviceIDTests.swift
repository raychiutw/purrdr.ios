import Foundation
import PurrdrCore
import PurrdrFeatures
import Security
import Testing

/// 這支裝置的推播 id 存在 Keychain(審查 #1、#2、#11):重裝 app 仍相同，0.45 以前 UserDefaults 的 id 搬進來沿用。
@Suite("推播裝置 id 存 Keychain")
struct KeychainPushDeviceIDTests {
    let defaults: UserDefaults
    let keychain = FakeKeychain()

    init() throws {
        let suite = "KeychainPushDeviceIDTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    func store() -> KeychainPushDeviceID {
        KeychainPushDeviceID(keychain: keychain, legacyDefaults: defaults)
    }

    @Test("第一次產生新的 UUID 並存起來，之後讀回同一個")
    func generatesOnceAndKeeps() throws {
        let first = try store().load()

        #expect(first.backendValue == first.rawValue)
        #expect(try store().load() == first)
        #expect(keychain.items.count == 1)
    }

    @Test("存成「第一次解鎖後、僅此裝置」,不進 iCloud 鑰匙圈")
    func storedOnlyOnThisDevice() throws {
        _ = try store().load()

        let attributes = try #require(keychain.addedAttributes.first)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test("0.45 以前 UserDefaults 的 id 搬進 Keychain 沿用，不換新(主機上的 push-<id> 才對得上)")
    func migratesLegacyID() throws {
        defaults.set("0123456789abcdef", forKey: KeychainPushDeviceID.legacyDefaultsKey)

        let id = try store().load()

        #expect(id.rawValue == "0123456789abcdef")
        #expect(defaults.string(forKey: KeychainPushDeviceID.legacyDefaultsKey) == nil)
        #expect(try store().load() == id)
    }

    @Test("Keychain 讀不到(例如還沒第一次解鎖):丟出錯誤，不產生新 id")
    func readFailureDoesNotGenerate() throws {
        keychain.copyStatus = errSecInteractionNotAllowed

        #expect(throws: PushDeviceIDError.unreadable(status: errSecInteractionNotAllowed)) { try store().load() }
        #expect(keychain.items.isEmpty)
    }

    @Test("讀不到之後解鎖了：沿用原本的 id")
    func retriesAfterReadFailure() throws {
        let original = try store().load()
        keychain.copyStatus = errSecInteractionNotAllowed
        #expect(throws: PushDeviceIDError.self) { try store().load() }

        keychain.copyStatus = nil

        #expect(try store().load() == original)
    }

    @Test("存不進 Keychain:丟出錯誤，舊的 UserDefaults id 留著下次再搬")
    func saveFailureKeepsLegacyID() throws {
        defaults.set("0123456789abcdef", forKey: KeychainPushDeviceID.legacyDefaultsKey)
        keychain.addStatus = errSecInteractionNotAllowed

        #expect(throws: PushDeviceIDError.unsaved(status: errSecInteractionNotAllowed)) { try store().load() }
        #expect(defaults.string(forKey: KeychainPushDeviceID.legacyDefaultsKey) == "0123456789abcdef")
    }
}
