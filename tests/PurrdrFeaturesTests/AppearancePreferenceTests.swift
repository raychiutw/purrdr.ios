import Foundation
import PurrdrFeatures
import Testing

/// 外觀設定(#246):自動(依系統)／淺色／深色，預設自動，app 內記住。
@Suite("外觀設定")
struct AppearancePreferenceTests {
    static func emptyDefaults() -> UserDefaults {
        UserDefaults(suiteName: "appearance-\(UUID().uuidString)")!
    }

    @Test("沒設定過是自動")
    func defaultsToAutomatic() {
        #expect(AppearancePreference.stored(in: Self.emptyDefaults()) == .automatic)
    }

    @Test("存過的選擇重開後讀回")
    func storedChoiceSurvivesRelaunch() {
        let defaults = Self.emptyDefaults()

        AppearancePreference.dark.store(in: defaults)

        #expect(AppearancePreference.stored(in: defaults) == .dark)
    }

    @Test("讀不懂的值退回自動")
    func unknownValueFallsBackToAutomatic() {
        let defaults = Self.emptyDefaults()
        defaults.set("sepia", forKey: AppearancePreference.storageKey)

        #expect(AppearancePreference.stored(in: defaults) == .automatic)
    }
}
