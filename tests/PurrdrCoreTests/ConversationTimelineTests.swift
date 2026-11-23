import Foundation
import PurrdrCore
import Testing

/// 對話時間軸(#481):列身分分配一次就不變;增量只產生新增、原地更新、移除。
@Suite("對話時間軸")
struct ConversationTimelineTests {
    static func userMessage(_ id: String, _ text: String) -> TranscriptMessage {
        TranscriptMessage(id: id, role: .user, date: nil, parts: [.text(text)])
    }

    static func agentText(_ id: String, _ text: String) -> TranscriptMessage {
        TranscriptMessage(id: id, role: .assistant, date: nil, parts: [.text(text)])
    }

    static func toolStep(_ id: String) -> TranscriptMessage {
        TranscriptMessage(id: id, role: .assistant, date: nil, parts: [
            .toolCall(id: "call-\(id)", name: "Bash", input: "ls", path: nil)
        ])
    }

    @Test("工具串多一個步驟，最後一列身分不變")
    func toolRunIdentityStaysWhenStepAppended() {
        var timeline = ConversationTimeline()
        _ = timeline.append([Self.userMessage("u1", "hi"), Self.toolStep("t1")])
        let identityBefore = timeline.items.last?.id

        let update = timeline.append([Self.toolStep("t2")])

        #expect(timeline.items.last?.id == identityBefore)
        #expect(timeline.items.count == 2)
        #expect(update.changes.count == 1)
        guard case .updated(let updatedRow, let position) = update.changes[0], case .toolRun(let run)? = updatedRow.item else {
            Issue.record("預期原地更新工具串")
            return
        }
        #expect(position == 1)
        #expect(run.steps.count == 2)
        #expect(run.id == run.expansionID)
    }

    @Test("工具串以第一個步驟命名")
    func toolRunNamedByFirstStep() {
        let items = Conversation.items(from: [Self.toolStep("t1"), Self.toolStep("t2")])
        #expect(items.first?.id == "t1:0")
    }

    @Test("重複的行被去重")
    func duplicateMessagesAreIgnored() {
        var timeline = ConversationTimeline()
        _ = timeline.append([Self.userMessage("u1", "hi")])

        let update = timeline.append([Self.userMessage("u1", "hi"), Self.userMessage("u1", "hi")])

        #expect(update.changes.isEmpty)
        #expect(timeline.items.count == 1)
    }

    @Test("往上補舊訊息併進最前面的工具串，列身分不變")
    func prependingOlderStepsKeepsRunIdentity() {
        var timeline = ConversationTimeline()
        _ = timeline.append([Self.toolStep("t5"), Self.agentText("a1", "done")])
        let identityBefore = timeline.items.first?.id

        let update = timeline.prependOlder([Self.userMessage("u0", "start"), Self.toolStep("t4")])

        #expect(update.cause == .olderLoaded)
        #expect(timeline.items.count == 3)
        guard case .toolRun(let run) = timeline.items[1] else {
            Issue.record("預期第二列是工具串")
            return
        }
        #expect(run.id == identityBefore)
        #expect(run.steps.count == 2)
    }

    @Test("捨棄過舊訊息後，留下的列身分不變")
    func droppingOldestKeepsRemainingIdentities() {
        var timeline = ConversationTimeline()
        _ = timeline.append([
            Self.userMessage("u1", "first"), Self.toolStep("t1"), Self.toolStep("t2"),
            Self.agentText("a1", "mid"), Self.toolStep("t3"),
        ])
        let identitiesBefore = timeline.items.map(\.id)
        #expect(identitiesBefore.count == 4)

        let update = timeline.dropOldest(messageCount: 2)

        // 丟掉 u1 與 t1:工具串剩 t2,仍用原本的列身分;後面兩列不變。
        #expect(timeline.items.map(\.id) == Array(identitiesBefore.dropFirst()))
        #expect(update.changes.contains { if case .removed(let id) = $0 { id == identitiesBefore[0] } else { false } })
    }

    @Test("新訊息的原因：使用者訊息為 userSent,其餘為 agentReply")
    func causeIsInferredFromAppendedRows() {
        var timeline = ConversationTimeline()
        #expect(timeline.append([Self.userMessage("u1", "hi")]).cause == .userSent)
        #expect(timeline.append([Self.agentText("a1", "yo")]).cause == .agentReply)
    }

    @Test("重新整理：取代全部訊息，沿用已存在列的身分")
    func resetKeepsExistingIdentities() {
        var timeline = ConversationTimeline()
        _ = timeline.append([Self.userMessage("u1", "hi"), Self.toolStep("t1")])
        let identitiesBefore = timeline.items.map(\.id)

        let update = timeline.reset([Self.userMessage("u1", "hi"), Self.toolStep("t1"), Self.toolStep("t2")])

        #expect(update.cause == .refreshed)
        #expect(timeline.items.map(\.id) == identitiesBefore)
    }
}
