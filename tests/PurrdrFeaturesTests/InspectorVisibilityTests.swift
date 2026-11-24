import Foundation
import PurrdrFeatures
import Testing

@MainActor
@Suite("iPad 對話右側 Inspector 開關(#521)")
struct InspectorVisibilityTests {
    @Test("沒存過時預設顯示；開關會寫進本機偏好，下一個視窗(新的導覽 model)沿用")
    func toggleIsRememberedAcrossWindows() throws {
        let suite = "InspectorVisibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsInspectorVisibilityStore(defaults: defaults)

        let first = TopNavigationModel(inspectorStore: store)
        #expect(first.isInspectorShown)

        first.toggleInspector()
        #expect(!first.isInspectorShown)
        #expect(defaults.object(forKey: "conversation.inspectorShown") as? Bool == false)

        let second = TopNavigationModel(inspectorStore: store)
        #expect(!second.isInspectorShown)

        second.toggleInspector()
        #expect(TopNavigationModel(inspectorStore: store).isInspectorShown)
    }

    @Test("直接設定 isInspectorShown(例如系統 sheet 被使用者下滑關掉)也存下來")
    func settingTheFlagPersists() {
        let store = InMemoryInspectorVisibilityStore(isShown: true)
        let model = TopNavigationModel(inspectorStore: store)

        model.isInspectorShown = false

        #expect(!store.load())
    }

    @Test("預設的 TopNavigationModel 不碰 UserDefaults，Inspector 預設顯示")
    func defaultModelStartsShown() {
        #expect(TopNavigationModel().isInspectorShown)
    }
}
