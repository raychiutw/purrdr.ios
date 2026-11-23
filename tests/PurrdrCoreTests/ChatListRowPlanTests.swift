import Foundation
import PurrdrCore
import Testing

/// 聊天列表的列組成與 snapshot 差異(#487)。
@Suite("聊天列表列組成")
struct ChatListRowPlanTests {
    @Test("頂端固定一列、之後是對話列、待送項目與底端的提示與工作中指示")
    func rowOrder() {
        let ids = ChatListRowPlan.ids(
            rowIDs: ["a", "b"], awayAnchorID: nil, pendingIDs: ["queued-1"], noticeID: "notice",
            showsPrompt: true, showsWorking: true)
        #expect(ids == [ChatListRowPlan.olderID, "a", "b", "queued-1", "notice", ChatListRowPlan.promptID, ChatListRowPlan.workingID])
    }

    @Test("離開期間分隔線放在錨點列前面")
    func awayDividerPrecedesAnchor() {
        let ids = ChatListRowPlan.ids(
            rowIDs: ["a", "b", "c"], awayAnchorID: "b", pendingIDs: [], noticeID: nil, showsPrompt: false, showsWorking: false)
        #expect(ids == [ChatListRowPlan.olderID, "a", ChatListRowPlan.awayID, "b", "c"])
    }

    @Test("錨點列不在列表裡時不畫分隔線")
    func awayAnchorMissingShowsNoDivider() {
        let ids = ChatListRowPlan.ids(
            rowIDs: ["a"], awayAnchorID: "gone", pendingIDs: [], noticeID: nil, showsPrompt: false, showsWorking: false)
        #expect(ids == [ChatListRowPlan.olderID, "a"])
    }

    @Test("空狀態沒有頂端固定列")
    func emptyStateOmitsOlderRow() {
        let ids = ChatListRowPlan.ids(
            includesOlder: false, rowIDs: [], awayAnchorID: nil, pendingIDs: [], noticeID: nil, showsPrompt: false, showsWorking: false)
        #expect(ids.isEmpty)
    }

    @Test("重複的 id 只留第一個")
    func duplicateIDsAreDropped() {
        let ids = ChatListRowPlan.ids(
            rowIDs: ["a", "a", ChatListRowPlan.workingID], awayAnchorID: nil, pendingIDs: [], noticeID: nil,
            showsPrompt: false, showsWorking: true)
        #expect(ids == [ChatListRowPlan.olderID, "a", ChatListRowPlan.workingID])
    }

    @Test("內容有變的列才需要重畫，新增與移除的列不在其中")
    func changedIDsOnlyForSurvivingRowsWithDifferentContent() {
        let previous = ["a": 1, "b": 2, "c": 3]
        let current = ["a": 1, "b": 20, "d": 4]
        #expect(ChatListRowPlan.changedIDs(previous: previous, current: current) == ["b"])
    }
}
