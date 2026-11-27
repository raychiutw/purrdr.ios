import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// #661:列表已知這個聊天的 session 時,找對話檔與讀主機狀態並行,不等 snapshot 回來才定位。
@MainActor
@Suite("點進聊天:找對話檔與主機狀態並行")
struct ConversationParallelLocateTests {
    typealias W = ConversationWorkingOpenTests
    typealias R = ConversationReadableMessageTests

    /// 列表看到的對話目標(Claude Code、W 的 session 與資料夾)。
    static func listTarget(session: String = W.sessionID) -> TranscriptTarget {
        TranscriptTarget(
            dialect: AgentCatalog.profile(for: .claude).transcript!,
            location: TranscriptLocation(locator: .claude, reference: .id(session), cwd: "/Users/demo/Projects/garden-journal"),
            sessionKey: session)
    }

    static func model(_ connection: FakeHostConnection, target: TranscriptTarget?) -> ConversationModel {
        ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: W.paneID,
            knownSessionID: W.sessionID, knownTarget: target, cache: InMemoryConversationCache(), clock: TestClock().clock)
    }

    static func locateCount(_ connection: FakeHostConnection) async -> Int {
        await connection.typedCalls.filter { $0 == "locateTranscript" }.count
    }

    @Test("列表有 session:snapshot 還沒回來,定位已經送出")
    func locateIsSentBeforeSnapshotReturns() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await R.answering(connection, lines: W.lines)
        await connection.hold("session.snapshot")
        let model = Self.model(connection, target: Self.listTarget())
        let poll = Task { await model.poll() }
        defer { poll.cancel() }

        try await waitUntil { await Self.locateCount(connection) == 1 }
        #expect(await connection.heldCount == 1, "snapshot 仍卡著,定位已先送出")
        await connection.releaseHeld()
        await poll.value
        #expect(await Self.locateCount(connection) == 1, "session 相符:沿用並行讀到的定位,不重送")
        #expect(!model.items.isEmpty)
    }

    @Test("snapshot 回來 session 已換:丟掉並行的定位,用新 session 重新定位")
    func sessionChangedRelocates() async throws {
        let newSession = "00000000-0000-0000-0000-0000000000cc"
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: .recorded("session.snapshot.ndjson") {
            SnapshotEdit.agent(W.paneID, in: &$0) {
                $0["agent_session"] = ["source": "herdr:claude", "agent": "claude", "kind": "id", "value": newSession]
            }
        })
        await R.answering(connection, lines: W.lines)
        await connection.hold("session.snapshot")
        let model = Self.model(connection, target: Self.listTarget())
        let poll = Task { await model.poll() }
        defer { poll.cancel() }

        try await waitUntil { await Self.locateCount(connection) == 1 }
        await connection.releaseHeld()
        await poll.value
        #expect(await Self.locateCount(connection) == 2, "新 session 要重新定位")
        #expect(!model.items.isEmpty)
    }

    @Test("列表沒有 session:照原本順序,snapshot 之後才定位")
    func noKnownTargetKeepsOrder() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await R.answering(connection, lines: W.lines)
        await connection.hold("session.snapshot")
        let model = Self.model(connection, target: nil)
        let poll = Task { await model.poll() }
        defer { poll.cancel() }

        try await waitUntil { await connection.heldCount == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await Self.locateCount(connection) == 0)
        await connection.releaseHeld()
        await poll.value
        #expect(await Self.locateCount(connection) == 1)
    }
}
