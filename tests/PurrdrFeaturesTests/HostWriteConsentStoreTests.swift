import Foundation
import PurrdrCore
import PurrdrFeatures
import Testing

/// 主機寫入的同意持久化;移除主機時清除該主機的所有同意。
@Suite("主機寫入的同意")
struct HostWriteConsentStoreTests {
    let suite = "purrdr.tests.consent.\(UUID().uuidString)"

    func store() -> UserDefaultsHostWriteConsentStore {
        UserDefaultsHostWriteConsentStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("同意存在 UserDefaults:重開 app 後仍在;撤銷只影響該功能")
    func persistsAcrossInstances() {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store().grant("claude-usage", host: "mac")
        store().grant("theme", host: "mac")
        store().revoke("theme", host: "mac")

        #expect(store().isGranted("claude-usage", host: "mac"))
        #expect(!store().isGranted("theme", host: "mac"))
        #expect(!store().isGranted("claude-usage", host: "linux"))
    }

    @Test("移除主機：清除該主機的所有同意，其他主機不受影響")
    func revokeAllForHost() {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store().grant("claude-usage", host: "mac")
        store().grant("theme", host: "mac")
        store().grant("claude-usage", host: "linux")

        store().revokeAll(host: "mac")

        #expect(!store().isGranted("claude-usage", host: "mac"))
        #expect(!store().isGranted("theme", host: "mac"))
        #expect(store().isGranted("claude-usage", host: "linux"))
    }
}
