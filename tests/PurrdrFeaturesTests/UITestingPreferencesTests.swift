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

    @Test func 重置後上一個測試留下的偏好都不見() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: ComposerSettings.returnSendsKey)

        UITestingPreferences.resetPersistedState(in: defaults, domain: name)

        #expect(defaults.object(forKey: ComposerSettings.returnSendsKey) == nil)
    }
}
