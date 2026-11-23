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

    @Test("使用者送出時捲到底並恢復跟隨;不加動畫(#497:長對話的回音動畫捲動會讓訊息區整片空白)")
    func userSentScrollsToBottomAndResumesFollowing() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 400))
        decider.receive(.timeline(Self.update(.userSent)))
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
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

    // MARK: - 唯一決策者:開啟定位、套用錨點、inset 對齊、動畫落地

    @Test("開啟後第一次有內容:不動畫捲到底,並跟隨最新")
    func openedWithContentScrollsToBottomWithoutAnimation() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 400))
        decider.receive(.openedWithContent)
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
        #expect(decider.isFollowingLatest)
        #expect(decider.flush(at: 1) == nil)
    }

    @Test("閱讀中套用內容:維持錨點列,不捲到底")
    func contentAppliedWhileReadingKeepsAnchorRow() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 300))
        decider.receive(.timeline(Self.update(.agentReply)))
        decider.receive(.contentApplied(anchorRowID: "r7"))
        #expect(decider.flush(at: 1) == .keepVisible(rowID: "r7"))
        #expect(decider.flush(at: 1) == nil)
        #expect(!decider.isFollowingLatest)
    }

    @Test("跟隨最新時套用內容沒有錨點,仍由批次決定捲到底")
    func contentAppliedWhileFollowingHasNoAnchor() {
        var decider = ConversationScrollDecider()
        decider.receive(.timeline(Self.update(.agentReply)))
        decider.receive(.contentApplied(anchorRowID: nil))
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
    }

    @Test("上方 inset 改變且原本貼著頂端:對齊頂端")
    func topInsetChangedWhileAtTopEdgePinsToTop() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 400))
        decider.receive(.topInsetChanged(wasAtTopEdge: true))
        #expect(decider.flush(at: 1) == .pinToTopEdge)
        #expect(decider.flush(at: 1) == nil)
    }

    @Test("上方 inset 改變但原本不在頂端:不動")
    func topInsetChangedAwayFromTopEdgeDoesNothing() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 400))
        decider.receive(.topInsetChanged(wasAtTopEdge: false))
        #expect(decider.flush(at: 1) == nil)
    }

    @Test("同一刻要捲到底時,頂端對齊併入,只輸出一個指令")
    func scrollToBottomSubsumesTopEdgePin() {
        var decider = ConversationScrollDecider()
        decider.receive(.topInsetChanged(wasAtTopEdge: true))
        decider.receive(.timeline(Self.update(.agentReply)))
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
        #expect(decider.flush(at: 1) == nil)
    }

    @Test("動畫捲動結束時還沒到底且跟隨中:再貼一次底部")
    func animationEndedShortOfBottomWhileFollowingResettles() {
        var decider = ConversationScrollDecider()
        decider.receive(.scrollAnimationEnded(distanceFromBottom: 30))
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
    }

    @Test("動畫捲動結束時已在底部或不跟隨:不動")
    func animationEndedAtBottomOrNotFollowingDoesNothing() {
        var atBottom = ConversationScrollDecider()
        atBottom.receive(.scrollAnimationEnded(distanceFromBottom: 0.5))
        #expect(atBottom.flush(at: 1) == nil)

        var reading = ConversationScrollDecider()
        reading.receive(.userScrolled(distanceFromBottom: 400))
        reading.receive(.scrollAnimationEnded(distanceFromBottom: 400))
        #expect(reading.flush(at: 1) == nil)
    }

    @Test("拖曳中延後頂端對齊")
    func topEdgePinDefersWhileDragging() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 400))
        decider.receive(.userBeganDragging)
        decider.receive(.topInsetChanged(wasAtTopEdge: true))
        #expect(decider.flush(at: 1) == nil)
    }

    @Test("閱讀中重新整理:維持原本可見的那一列,不跳到最新")
    func refreshedWhileReadingKeepsVisibleRow() {
        var decider = ConversationScrollDecider()
        decider.receive(.userScrolled(distanceFromBottom: 300))
        decider.receive(.firstVisibleRowChanged(id: "r5"))
        decider.receive(.timeline(Self.update(.refreshed, ["r1", "r2"])))
        #expect(decider.flush(at: 1) == .keepVisible(rowID: "r5"))
        #expect(decider.flush(at: 2) == nil)
        #expect(!decider.isFollowingLatest)
    }

    @Test("跟隨最新時重新整理:仍貼底,不另外維持位置")
    func refreshedWhileFollowingStaysAtBottom() {
        var decider = ConversationScrollDecider()
        decider.receive(.firstVisibleRowChanged(id: "r5"))
        decider.receive(.timeline(Self.update(.refreshed, ["r1"])))
        #expect(decider.flush(at: 1) == .scrollToBottom(animated: false))
    }
}
