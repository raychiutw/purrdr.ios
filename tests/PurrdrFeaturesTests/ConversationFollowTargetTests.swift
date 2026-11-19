import PurrdrFeatures
import Testing

/// 跟隨尾端的捲動目標(#191、#210):有列時一律捲到最底下那一列，不捲到內容底部(會多捲一個底部 inset,停在內容外)。
@Suite("跟隨尾端的捲動目標")
struct ConversationFollowTargetTests {
    @Test("送出後 Agent 工作中：捲到工作中指示那一列")
    func workingRowAfterSending() {
        let target = ConversationFollowTarget.target(
            showsWorkingRow: true, showsPanel: false, showsPromptCard: false, lastEntryID: "echo:1")
        #expect(target == .row(ConversationFollowTarget.workingRowID))
    }

    @Test("送出後指示還沒出現：捲到剛送出的那一列")
    func lastEntryAfterSending() {
        let target = ConversationFollowTarget.target(
            showsWorkingRow: false, showsPanel: false, showsPromptCard: false, lastEntryID: "echo:1")
        #expect(target == .row("echo:1"))
    }

    @Test("沒有工作中指示時，面板與問題卡片在最底下")
    func panelThenPromptCard() {
        #expect(ConversationFollowTarget.target(showsWorkingRow: false, showsPanel: true, showsPromptCard: true, lastEntryID: "a")
            == .row(ConversationFollowTarget.panelRowID))
        #expect(ConversationFollowTarget.target(showsWorkingRow: false, showsPanel: false, showsPromptCard: true, lastEntryID: "a")
            == .row(ConversationFollowTarget.promptRowID))
    }

    @Test("沒有任何列：捲到內容底部")
    func bottomEdgeWhenEmpty() {
        #expect(ConversationFollowTarget.target(showsWorkingRow: false, showsPanel: false, showsPromptCard: false, lastEntryID: nil)
            == .bottomEdge)
    }
}
