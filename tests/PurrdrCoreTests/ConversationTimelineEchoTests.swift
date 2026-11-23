import Foundation
import PurrdrCore
import Testing

/// 對話時間軸(#485):回音原地確認、往上補、展開狀態與 Markdown 跟著列。
@Suite("對話時間軸:回音、舊訊息、狀態")
struct ConversationTimelineEchoTests {
    static func echo(_ id: String, _ text: String, state: PromptEcho.State = .sent) -> PromptEcho {
        PromptEcho(id: id, text: text, date: Date(timeIntervalSince1970: 1_000), state: state, knownUserIDs: [])
    }

    static func timelineWithEcho() -> ConversationTimeline {
        var timeline = ConversationTimeline()
        _ = timeline.setEchoes([echo("e1", "hello")])
        return timeline
    }

    @Test("送出回音:新增一列,原因是使用者送出")
    func echoInsertsRow() {
        var timeline = ConversationTimeline()

        let update = timeline.setEchoes([Self.echo("e1", "hello")])

        #expect(update.cause == .userSent)
        #expect(update.changes.count == 1)
        guard case .inserted(let row, let position)? = update.changes.first else {
            Issue.record("預期新增回音列")
            return
        }
        #expect(row.id == "echo:e1")
        #expect(position == 0)
    }

    @Test("回音確認後原地更新:同一個列身分,不是刪除再新增")
    func confirmedEchoUpdatesInPlace() {
        var timeline = Self.timelineWithEcho()

        let update = timeline.append([ConversationTimelineTests.userMessage("u1", "hello")])

        #expect(update.cause == .userSent)
        #expect(update.changes.count == 1)
        guard case .updated(let row, let position)? = update.changes.first else {
            Issue.record("預期原地更新,不是刪除再新增:\(update.changes)")
            return
        }
        #expect(row.id == "echo:e1")
        #expect(position == 0)
        guard case .user(let bubble)? = row.item else {
            Issue.record("預期內容變成正式的使用者訊息")
            return
        }
        #expect(bubble.id == "u1")
        #expect(timeline.pendingEchoes.isEmpty)
        #expect(timeline.rows.map(\.id) == ["echo:e1"])
    }

    @Test("確認後的列身分在後續新增內容時不變")
    func confirmedRowKeepsIdentityAfterMoreContent() {
        var timeline = Self.timelineWithEcho()
        _ = timeline.append([ConversationTimelineTests.userMessage("u1", "hello")])

        let update = timeline.append([ConversationTimelineTests.agentText("a1", "hi")])

        #expect(timeline.rows.map(\.id) == ["echo:e1", "a1:0"])
        #expect(update.changes.count == 1)
        if case .inserted? = update.changes.first {} else { Issue.record("預期只新增 Agent 那一列") }
    }

    @Test("送出之前就存在的使用者訊息不能確認回音")
    func echoNotConfirmedByEarlierMessage() {
        var timeline = ConversationTimeline()
        _ = timeline.append([ConversationTimelineTests.userMessage("u0", "again")])
        var echo = Self.echo("e1", "again")
        echo.knownUserIDs = ["u0"]

        _ = timeline.setEchoes([echo])

        #expect(timeline.pendingEchoes.map(\.id) == ["e1"])
        #expect(timeline.rows.count == 2)
    }

    @Test("回音改狀態:原地更新")
    func echoStateChangeUpdatesInPlace() {
        var timeline = ConversationTimeline()
        _ = timeline.setEchoes([Self.echo("e1", "hello", state: .sending)])

        let update = timeline.setEchoes([Self.echo("e1", "hello", state: .failed(.noResponse))])

        #expect(update.changes.count == 1)
        if case .updated(let row, _)? = update.changes.first { #expect(row.id == "echo:e1") } else { Issue.record("預期原地更新") }
    }

    @Test("往上補舊訊息:既有列身分不變,新列是往上補")
    func olderMessagesArePrependedAndExistingRowsStay() {
        var timeline = ConversationTimeline()
        _ = timeline.append([ConversationTimelineTests.userMessage("u2", "later"), ConversationTimelineTests.agentText("a2", "answer")])
        let identitiesBefore = timeline.rows.map(\.id)

        let update = timeline.prependOlder([ConversationTimelineTests.userMessage("u1", "earlier"), ConversationTimelineTests.agentText("a1", "old")])

        #expect(update.cause == .olderLoaded)
        #expect(Array(timeline.rows.map(\.id).suffix(2)) == identitiesBefore)
        #expect(update.changes.count == 2)
        for change in update.changes {
            guard case .prepended(let row, let position) = change else {
                Issue.record("預期都是往上補:\(change)")
                continue
            }
            #expect(["u1", "a1:0"].contains(row.id))
            #expect(position < 2)
        }
    }

    @Test("展開狀態跨增量保留,列被移除後清掉")
    func expansionSurvivesIncrementsAndIsPrunedWithRow() {
        var timeline = ConversationTimeline()
        _ = timeline.append([ConversationTimelineTests.userMessage("u1", "go"), ConversationTimelineTests.toolStep("t1")])
        let toolRunRowID = timeline.rows.last?.id ?? "missing"
        timeline.setExpanded(true, rowID: toolRunRowID)

        _ = timeline.append([ConversationTimelineTests.toolStep("t2")])
        _ = timeline.prependOlder([ConversationTimelineTests.userMessage("u0", "before")])
        _ = timeline.reset([ConversationTimelineTests.userMessage("u0", "before"), ConversationTimelineTests.userMessage("u1", "go"), ConversationTimelineTests.toolStep("t1")])

        #expect(timeline.isExpanded(rowID: toolRunRowID))

        _ = timeline.reset([ConversationTimelineTests.userMessage("u9", "new")])
        #expect(!timeline.isExpanded(rowID: toolRunRowID))
    }

    @Test("子項展開:Agent 新增步驟、往上補、併列後仍展開,不同列同名子項互不影響")
    func partExpansionSurvivesIncrementsAndIsPerRow() {
        var timeline = ConversationTimeline()
        _ = timeline.append([ConversationTimelineTests.userMessage("u1", "go"), ConversationTimelineTests.toolStep("t1")])
        let toolRunRowID = timeline.rows.last?.id ?? "missing"
        timeline.setExpanded(true, rowID: toolRunRowID, partID: "t1")

        #expect(timeline.isExpanded(rowID: toolRunRowID, partID: "t1"))
        #expect(!timeline.isExpanded(rowID: toolRunRowID))
        #expect(!timeline.isExpanded(rowID: toolRunRowID, partID: "t2"))
        #expect(!timeline.isExpanded(rowID: "other", partID: "t1"))

        _ = timeline.append([ConversationTimelineTests.toolStep("t2")])
        _ = timeline.prependOlder([ConversationTimelineTests.userMessage("u0", "before")])

        #expect(timeline.isExpanded(rowID: toolRunRowID, partID: "t1"))
    }

    @Test("子項收起後清掉;列被移除時連子項一起清掉")
    func partExpansionCollapsesAndIsPrunedWithRow() {
        var timeline = ConversationTimeline()
        _ = timeline.append([ConversationTimelineTests.userMessage("u1", "go"), ConversationTimelineTests.toolStep("t1")])
        let toolRunRowID = timeline.rows.last?.id ?? "missing"
        timeline.setExpanded(true, rowID: toolRunRowID, partID: "t1")
        timeline.setExpanded(false, rowID: toolRunRowID, partID: "t1")
        #expect(!timeline.isExpanded(rowID: toolRunRowID, partID: "t1"))

        timeline.setExpanded(true, rowID: toolRunRowID, partID: "t1")
        _ = timeline.reset([ConversationTimelineTests.userMessage("u9", "new")])
        #expect(!timeline.isExpanded(rowID: toolRunRowID, partID: "t1"))
    }

    @Test("同一則訊息的 Markdown 只解析一次;文字變了才重解析")
    func markdownIsParsedOncePerText() {
        var timeline = ConversationTimeline()
        _ = timeline.append([ConversationTimelineTests.agentText("a1", "# 標題\n\n內文")])
        guard case .agentText(let text)? = timeline.rows.first?.item else {
            Issue.record("預期 Agent 文字")
            return
        }

        let first = timeline.markdownBlocks(for: text)
        let second = timeline.markdownBlocks(for: text)

        #expect(first == second)
        #expect(timeline.markdownParseCount == 1)

        var edited = text
        edited.markdown = "改過的內文"
        _ = timeline.markdownBlocks(for: edited)
        #expect(timeline.markdownParseCount == 2)
    }
}
