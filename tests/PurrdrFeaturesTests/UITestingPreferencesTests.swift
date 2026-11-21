import Foundation
import Testing

@testable import PurrdrAgentFeatures
@testable import PurrdrFeatures

@MainActor
struct UITestingPreferencesTests {
    private func suite() -> (UserDefaults, String) {
        let name = "UITestingPreferencesTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func 重置後上一個測試留下的偏好與列表檢視都不見() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: ComposerSettings.returnSendsKey)
        UserDefaultsAgentListModeStore(defaults: defaults).save(.spaces)

        UITestingPreferences.resetPersistedState(in: defaults, domain: name)

        #expect(defaults.object(forKey: ComposerSettings.returnSendsKey) == nil)
        #expect(UserDefaultsAgentListModeStore(defaults: defaults).load() == nil)
    }

    @Test func 列表檢視存在UserDefaults時重新讀取仍是上次選的() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        UserDefaultsAgentListModeStore(defaults: defaults).save(.spaces)
        #expect(UserDefaultsAgentListModeStore(defaults: defaults).load() == .spaces)
    }
}
