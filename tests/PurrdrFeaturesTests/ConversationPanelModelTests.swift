import PurrdrFeatures
import Testing

/// 聊天頂列用量環開的面板(#617):快捷鍵經視窗導覽模型送出「開關面板」要求,聊天畫面依要求次數切換;
/// 不再有 Inspector 的本機偏好(開關狀態是畫面的暫時狀態,不會每開一個聊天就跳出)。
@MainActor
@Suite("聊天面板開關要求(#617)")
struct ConversationPanelModelTests {
    @Test("Option-Command-I 每按一次,面板開關要求加一")
    func shortcutRequestsToggle() {
        let model = TopNavigationModel()
        #expect(model.conversationPanelToggleCount == 0)
        model.perform(.toggleConversationPanel, visibleAgents: [])
        #expect(model.conversationPanelToggleCount == 1)
        model.toggleConversationPanel()
        #expect(model.conversationPanelToggleCount == 2)
    }
}
