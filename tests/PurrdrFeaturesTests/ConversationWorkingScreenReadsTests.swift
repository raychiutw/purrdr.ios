import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 工作中讀 pane 畫面的節奏(#204):聊天每 2 秒輪詢，工作中每 6 秒才讀一次畫面;需要你照舊每輪讀。
/// 假連線依 method 比對，沒預期的 `pane.read` 也會記在 `requests` 裡。
@MainActor
@Suite("對話：工作中讀畫面的節奏")
struct ConversationWorkingScreenReadsTests {
    static let paneID = "w1:p6"

    static let writingScreen = """
        ⏺ The photo tags are now grouped by season, and the untagged ones
          are listed at the end so they are easy to find.

        ✻ Pondering… (esc to interrupt)
        ❯
        """

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_794_614_400)
        var conversationClock: ConversationClock { ConversationClock(now: { self.now }) }
    }

    static func snapshot(_ status: String) -> Data {
        Fixtures.modifiedLine("session.snapshot.ndjson") { SnapshotEdit.agent(paneID, in: &$0) { $0["agent_status"] = status } }
    }

    static func paneRead(text: String) -> Data {
        Fixtures.modifiedLine("pane.read.visible.ndjson") { response in
            guard var result = response["result"] as? [String: Any], var read = result["read"] as? [String: Any] else { return }
            read["text"] = text
            result["read"] = read
            response["result"] = result
        }
    }

    static func model(_ connection: FakeHostConnection, clock: Clock) -> ConversationModel {
        ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: paneID,
            knownSessionID: nil, cache: InMemoryConversationCache(), clock: clock.conversationClock)
    }

    static func paneReads(_ connection: FakeHostConnection) async -> Int {
        await connection.requests.filter { $0.contains(#""method":"pane.read""#) }.count
    }

    @Test("工作中每 2 秒輪詢：每 6 秒才讀一次畫面，中間的輪詢沿用上次的背景 agents 窗格")
    func workingReadsScreenEverySixSeconds() async throws {
        let connection = FakeHostConnection()
        let clock = Clock()
        let model = Self.model(connection, clock: clock)
        for _ in 0..<6 { await connection.expect(.snapshot, wire: Self.snapshot("working")) }
        for _ in 0..<2 { await connection.expect(.paneRead, wire: Fixtures.data("pane.read.agents-pane.ndjson")) }

        for _ in 0..<6 {
            await model.poll()
            #expect(model.agentsPane?.rows.count == 5)
            clock.now += 2
        }

        #expect(await Self.paneReads(connection) == 2)
        #expect(await connection.unmetExpectations.isEmpty)
    }

    @Test("即時預覽：兩次讀畫面之間的輪詢沿用上次的預覽")
    func livePreviewKeptBetweenScreenReads() async throws {
        let connection = FakeHostConnection()
        let clock = Clock()
        let model = Self.model(connection, clock: clock)
        for _ in 0..<3 { await connection.expect(.snapshot, wire: Self.snapshot("working")) }
        await connection.expect(.paneRead, wire: Self.paneRead(text: Self.writingScreen))

        await model.poll()
        let preview = try #require(model.livePreview)
        for _ in 0..<2 {
            clock.now += 2
            await model.poll()
            #expect(model.livePreview == preview)
        }

        #expect(await Self.paneReads(connection) == 1)
    }

    @Test("需要你：工作中剛讀過畫面，下一輪變成需要你仍立刻讀畫面顯示提示")
    func blockedRightAfterWorkingReadShowsPromptImmediately() async throws {
        let connection = FakeHostConnection()
        let clock = Clock()
        let model = Self.model(connection, clock: clock)
        await connection.expect(.snapshot, wire: Self.snapshot("working"))
        await connection.expect(.paneRead, wire: Self.paneRead(text: Self.writingScreen))
        await connection.expect(.snapshot, wire: Self.snapshot("blocked"))
        await connection.expect(.paneRead, wire: Self.paneRead(text: PaneScreens.text("claude-bash")))

        await model.poll()
        clock.now += 2
        await model.poll()

        #expect(model.agentStatus == .blocked)
        #expect(model.prompt?.question == "Do you want to proceed?")
        #expect(await connection.unmetExpectations.isEmpty)
    }
}
