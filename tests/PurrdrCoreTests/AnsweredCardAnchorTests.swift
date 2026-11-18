import Foundation
import PurrdrCore
import Testing

/// 已回答卡片的去留(#213):錨點是送出回答當下的最後一列;Agent 寫出新的回覆文字才收起，只有工具步驟時多留一段時間。
@Suite("已回答卡片的去留")
struct AnsweredCardAnchorTests {
    static let sentAt = Date(timeIntervalSince1970: 1_000_000)
    static let anchor = AnsweredCardAnchor(lastEntryID: "reply-1", sentAt: sentAt)
    static let earlier = AnsweredCardAnchor.Row(id: "reply-1", showsText: true)

    static func after(_ seconds: TimeInterval) -> Date { sentAt.addingTimeInterval(seconds) }

    @Test("對話還沒有新的一列：過很久也留著")
    func staysUntilConversationMovesOn() {
        #expect(Self.anchor.isShowing(rows: [Self.earlier], at: Self.after(600)))
    }

    @Test("寫得快：同一輪就有新的工具步驟，卡片仍留著")
    func staysWhenOnlyStepsFollowQuickly() {
        let rows = [Self.earlier, .init(id: "tools-1", showsText: false)]
        #expect(Self.anchor.isShowing(rows: rows, at: Self.after(1)))
    }

    @Test("只有工具步驟：留到工具步驟的保留時間後收起")
    func hidesAfterStepsOnlyShowing() {
        let rows = [Self.earlier, .init(id: "tools-1", showsText: false)]
        #expect(Self.anchor.isShowing(rows: rows, at: Self.after(AnsweredCardAnchor.stepsOnlyShowing - 1)))
        #expect(!Self.anchor.isShowing(rows: rows, at: Self.after(AnsweredCardAnchor.stepsOnlyShowing)))
    }

    @Test("新的回覆文字：至少顯示最短時間，之後收起")
    func hidesOnReplyTextAfterMinimumShowing() {
        let rows = [Self.earlier, .init(id: "tools-1", showsText: false), .init(id: "reply-2", showsText: true)]
        #expect(Self.anchor.isShowing(rows: rows, at: Self.after(1)))
        #expect(!Self.anchor.isShowing(rows: rows, at: Self.after(AnsweredCardAnchor.minimumShowing)))
    }

    @Test("送出時對話還是空的，之後第一列是回覆文字：收起")
    func hidesWhenFirstReplyArrives() {
        let anchor = AnsweredCardAnchor(lastEntryID: nil, sentAt: Self.sentAt)
        #expect(anchor.isShowing(rows: [], at: Self.after(600)))
        #expect(!anchor.isShowing(rows: [.init(id: "reply-1", showsText: true)], at: Self.after(AnsweredCardAnchor.minimumShowing)))
    }

    @Test("錨點那一列已被修剪：剩下的列都算新的")
    func trimmedAnchorCountsAllRowsAsNew() {
        let rows = [AnsweredCardAnchor.Row(id: "reply-9", showsText: true)]
        #expect(!Self.anchor.isShowing(rows: rows, at: Self.after(AnsweredCardAnchor.minimumShowing)))
    }
}
