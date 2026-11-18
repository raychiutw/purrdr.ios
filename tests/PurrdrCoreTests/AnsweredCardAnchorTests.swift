import PurrdrCore
import Testing

/// 已回答卡片的去留(#213):回答送達後對話多了新的一列，卡片就不再釘在對話底部。
@Suite("已回答卡片的去留")
struct AnsweredCardAnchorTests {
    @Test("送達後對話還沒有新的一列：卡片留著")
    func staysUntilConversationMovesOn() {
        let anchor = AnsweredCardAnchor(lastEntryID: "reply-1")
        #expect(anchor.isShowing(lastEntryID: "reply-1"))
    }

    @Test("Agent 接著輸出(最後一列換了):卡片收起")
    func hidesWhenAgentWritesMore() {
        let anchor = AnsweredCardAnchor(lastEntryID: "reply-1")
        #expect(!anchor.isShowing(lastEntryID: "reply-2"))
    }

    @Test("送達時對話還是空的，之後出現第一列：卡片收起")
    func hidesWhenFirstEntryArrives() {
        let anchor = AnsweredCardAnchor(lastEntryID: nil)
        #expect(anchor.isShowing(lastEntryID: nil))
        #expect(!anchor.isShowing(lastEntryID: "reply-1"))
    }
}
