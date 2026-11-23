import Foundation
import PurrdrCore
import Testing

/// 捲動決策者(#486):事件序列進、每一刻最多一個指令出。
@Suite("捲動決策者")
struct ConversationScrollDeciderTests {
    static func row(_ id: String) -> ConversationRow {
        ConversationRow(id: id, entry: .item(.agentText(AgentText(id: id, markdown: id, date: nil))))
    }

    static func update(_ cause: ConversationTimeline.Cause, _ ids: [String] = ["r1"]) -> ConversationTimeline.Update {
        ConversationTimeline.Update(cause: cause, changes: ids.enumerated().map { .inserted(row($1), at: $0) })
    }

    @Test("同一刻同時有內容變更與高度變化，只輸出一個指令")
    func contentAndHeightChangeYieldOneCommand() {
        var decider = ConversationScrollDecider()
        decider.receive(.timeline(Self.update(.agentReply)))
        decider.receive(.inputBarHeightChanged)
        decider.receive(.keyboardHeightChanged)
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
        #expect(decider.flush(at: 1) == nil)
    }

    @Test("使用者往上捲後，Agent 回覆不觸發捲動")
    func agentReplyAfterUserScrolledUpDoesNotScroll() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 400))
        decider.receive(.timeline(Self.update(.agentReply)))
        #expect(decider.flush(at: 1) == nil)
        #expect(!decider.isFollowingLatest)
    }

    @Test("捲回底部附近時恢復跟隨")
    func scrollingBackNearBottomResumesFollowing() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 400))
        decider.receive(.userScrolled(distanceFromBottom: 20))
        decider.receive(.timeline(Self.update(.agentReply)))
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
    }

    @Test("程式造成的捲動不會關掉跟隨")
    func programmaticScrollDoesNotStopFollowing() {
        var decider = ConversationScrollDecider()
        decider.receive(.layoutMeasured(distanceFromBottom: 900))
        #expect(decider.isFollowingLatest)
        decider.receive(.timeline(Self.update(.agentReply)))
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
    }

    @Test("使用者送出時捲到底並恢復跟隨")
    func userSentScrollsToBottomAndResumesFollowing() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 400))
        decider.receive(.timeline(Self.update(.userSent)))
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: true))
        #expect(decider.isFollowingLatest)
    }

    @Test("鍵盤動畫中延後套用，結束後才捲")
    func keyboardAnimationDefersUntilFinished() {
        var decider = ConversationScrollDecider()
        decider.receive(.keyboardAnimation(isRunning: true))
        decider.receive(.timeline(Self.update(.agentReply)))
        #expect(decider.flush(at: 1) == nil)
        decider.receive(.keyboardAnimation(isRunning: false))
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
    }

    @Test("拖曳中與選單開著時延後套用")
    func draggingAndMenuDefer() {
        var decider = ConversationScrollDecider()
        decider.receive(.userBeganDragging)
        decider.receive(.timeline(Self.update(.agentReply)))
        #expect(decider.flush(at: 1) == nil)
        decider.receive(.userEndedDragging(distanceFromBottom: 10))
        decider.receive(.menu(isOpen: true))
        #expect(decider.flush(at: 1) == nil)
        decider.receive(.menu(isOpen: false))
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
    }

    @Test("新內容約每 100 ms 批次一次")
    func contentIsBatchedEvery100Milliseconds() {
        var decider = ConversationScrollDecider()
        decider.receive(.timeline(Self.update(.agentReply)))
        #expect(decider.flush(at: 10) == .scrollToBottom(animated: false))
        decider.receive(.timeline(Self.update(.agentReply, ["r2"])))
        #expect(decider.flush(at: 10.05) == nil)
        #expect(decider.flush(at: 10.1) == .scrollToBottom(animated: false))
    }

    @Test("跳到最新只產生一個指令，目標是最後一列")
    func jumpToLatestTargetsLastRowOnce() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 600))
        decider.receive(.timeline(Self.update(.agentReply, ["r1", "r2", "r3"])))
        decider.receive(.jumpToLatest(lastRowID: "r3"))
        #expect(decider.flush(at: 1) == .scrollToRow(id: "r3", animated: true))
        #expect(decider.flush(at: 2) == nil)
        #expect(decider.isFollowingLatest)
    }

    @Test("往上補舊訊息時，維持目前可見列的位置")
    func olderLoadedKeepsVisibleRow() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 300))
        decider.receive(.firstVisibleRowChanged(id: "r5"))
        decider.receive(.timeline(Self.update(.olderLoaded, ["r1", "r2"])))
        #expect(decider.flush(at: 1) == .keepVisible(rowID: "r5"))
        #expect(!decider.isFollowingLatest)
    }

    @Test("沒有變更的更新不產生指令")
    func emptyUpdateYieldsNothing() {
        var decider = ConversationScrollDecider()
        decider.receive(.timeline(.init(cause: .agentReply, changes: [])))
        #expect(decider.flush(at: 1) == nil)
    }
}
