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

    /// 列表看到的對話目標:與 snapshot 回報同一個 pane 時算出的相同(取自錄製的 snapshot)。
    static func listTarget() async throws -> TranscriptTarget {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        let snapshot = try await HerdrClient(connection: connection).snapshot()
        return try #require(snapshot.agents.first { $0.paneID == W.paneID }?.transcriptTarget)
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
        let model = Self.model(connection, target: try await Self.listTarget())
        let poll = Task { await model.poll() }
        defer { poll.cancel() }

        try await waitUntil { await Self.locateCount(connection) == 1 }
        #expect(await connection.heldCount == 1, "snapshot 仍卡著,定位已先送出")
        await connection.releaseHeld()
        await poll.value
        let calls = await connection.typedCalls
        #expect(calls.filter { $0 == "locateTranscript" }.count == 1, "session 相符:沿用並行讀到的定位,不重送 \(calls)")
        #expect(!model.items.isEmpty)
    }

    @Test("snapshot 回來 session 已換:丟掉並行的定位,用新 session 重新定位")
    func sessionChangedRelocates() async throws {
        let newSession = "00000000-0000-0000-0000-0000000000cc"
        let connection = FakeHostConnection()
        // 以真實回應為底,只把這個 pane 的 session 換成新的(`/clear` 之後的樣子)。
        let original = String(decoding: Fixtures.data("session.snapshot.ndjson"), as: UTF8.self)
        #expect(original.contains(W.sessionID))
        await connection.expect(.snapshot, wire: Data(original.replacingOccurrences(of: W.sessionID, with: newSession).utf8))
        await R.answering(connection, lines: W.lines)
        await connection.hold("session.snapshot")
        let model = Self.model(connection, target: try await Self.listTarget())
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
        // 讓 poll 與它可能開出的並行工作都跑到卡住或結束為止(讓出執行緒的次數,不是時間),再放行 snapshot。
        for _ in 0..<500 { await Task.yield() }
        await connection.releaseHeld()
        await poll.value
        // 放行當下已送進來的請求裡沒有定位;定位是 snapshot 之後才送的(確定性:不靠等多久)。
        let beforeRelease = await connection.typedCallsAtLastRelease
        #expect(!beforeRelease.contains("locateTranscript"), "snapshot 還卡著時不該先定位 \(beforeRelease)")
        #expect(await Self.locateCount(connection) == 1, "snapshot 之後才定位一次")
    }
}
