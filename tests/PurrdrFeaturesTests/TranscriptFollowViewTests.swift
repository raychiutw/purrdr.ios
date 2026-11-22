import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 聊天與 Subagent 畫面等主機連線的追蹤事件，不自己定時讀尾端(#165)。假連線像 HTTPS 一樣推送事件;
/// 畫面的等待一律不到期，所以新內容只能從追蹤來。
@MainActor
@Suite("畫面等對話紀錄追蹤")
struct TranscriptFollowViewTests {
    static let paneID = "w1:p6"
    nonisolated static let sessionID = "00000000-0000-0000-0000-000000000001"
    nonisolated static let path = "/Users/demo/.claude/projects/-Users-demo-Projects-garden-journal/\(sessionID).jsonl"
    nonisolated static let lines = Fixtures.transcriptLines()
    /// 視窗讀到的整個 fixture 的 byte 數(含每行換行)。
    nonisolated static let size = lines.reduce(0) { $0 + $1.utf8.count + 1 }

    /// 定位回報 `path`;視窗(與探測大小的尾端讀取)回整個 fixture。
    static func answering(_ connection: FakeHostConnection) async {
        await connection.answerTranscripts { request in
            switch request {
            case .locate:
                return Data("\(path)\n\(size)\n".utf8)
            case .window:
                return Data(("0 \(size)\n" + lines.map { "\($0.utf8.count)\t\($0)\n" }.joined()).utf8)
            case .tail(_, let cursor, _) where cursor == TranscriptReader.probeCursor:
                return Data("\(size)\n".utf8)
            default:
                throw FakeHostConnectionError.unsupported
            }
        }
    }

    /// Agent 工作中寫出的新訊息(使用者打的字)。
    static let addedLine = ConversationCatchUpTests.userLine(1, bytes: 30)
    static let addedChunk = TranscriptChunk(start: size, end: size + addedLine.utf8.count + 1, lines: [addedLine])

    static func windowReads(_ connection: FakeHostConnection) async -> Int {
        await connection.transcriptRequests.filter { if case .window = $0 { true } else { false } }.count
    }

    /// 開啟時探測大小之外的尾端讀取(輪詢形狀的讀法)。
    static func tailReads(_ connection: FakeHostConnection) async -> Int {
        await connection.transcriptRequests.filter {
            switch $0 {
            case .tail(_, let cursor, _): cursor != TranscriptReader.probeCursor
            case .catchUp: true
            default: false
            }
        }.count
    }

    @Test("聊天：開啟後從游標追蹤，推送的新訊息不等輪詢就顯示，畫面不讀尾端")
    func conversationShowsPushedLinesWithoutPolling() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await Self.answering(connection)
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Self.paneID,
            knownSessionID: Self.sessionID, cache: InMemoryConversationCache(), clock: TestClock().clock)
        let chat = Task { await model.run(sleep: RecordingSleeper().sleep) }
        defer { chat.cancel() }
        try await waitUntil { await connection.transcriptFollowOpenings.count == 1 }
        let shown = model.items.count

        await connection.send(.appended(Self.addedChunk), toFollow: 0)
        try await waitUntil { await MainActor.run { model.items.count == shown + 1 } }

        #expect(await connection.transcriptFollowOpenings == [TranscriptFollowOpening(path: Self.path, cursor: Self.size)])
        #expect(await Self.tailReads(connection) == 0)
    }

    @Test("聊天：追蹤送 replaced 後重讀視窗，並從新游標再追蹤")
    func conversationReopensWindowWhenReplaced() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await Self.answering(connection)
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Self.paneID,
            knownSessionID: Self.sessionID, cache: InMemoryConversationCache(), clock: TestClock().clock)
        let chat = Task { await model.run(sleep: RecordingSleeper().sleep) }
        defer { chat.cancel() }
        try await waitUntil { await connection.transcriptFollowOpenings.count == 1 }

        await connection.send(.replaced(size: Self.size), toFollow: 0)
        try await waitUntil { await connection.transcriptFollowOpenings.count == 2 }

        #expect(await Self.windowReads(connection) == 2)
        #expect(await connection.transcriptFollowOpenings.last == TranscriptFollowOpening(path: Self.path, cursor: Self.size))
        #expect(await Self.tailReads(connection) == 0)
    }

    @Test("聊天：場景非作用中再回來，舊的 run 晚於新的 run 結束時，不關掉新的追蹤(#219)")
    func lateEndingOldRunKeepsNewRunFollowing() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await Self.answering(connection)
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Self.paneID,
            knownSessionID: Self.sessionID, cache: InMemoryConversationCache(), clock: TestClock().clock)
        await connection.hold("session.snapshot")
        let inactiveRun = Task { await model.run(sleep: RecordingSleeper().sleep) }
        try await waitUntil { await connection.heldCount == 1 }

        inactiveRun.cancel()
        let activeRun = Task { await model.run(sleep: RecordingSleeper().sleep) }
        defer { activeRun.cancel() }
        try await waitUntil { await connection.transcriptFollowOpenings.count == 1 }
        await connection.releaseHeld()
        await inactiveRun.value

        let shown = model.items.count
        #expect(await connection.transcriptFollowsClosed == [false])
        await connection.send(.appended(Self.addedChunk), toFollow: 0)
        try await waitUntil { await MainActor.run { model.items.count == shown + 1 } }
    }

    @Test("Subagent:開啟後從游標追蹤，推送的新訊息不等輪詢就顯示，換檔後重讀視窗")
    func subagentFollowsPushedLines() async throws {
        let connection = FakeHostConnection()
        await Self.answering(connection)
        let model = SubagentModel(
            transcripts: TranscriptReader(connection: connection), transcriptPath: Self.path, title: "Review", subtitle: nil, status: .running)
        let run = Task { await model.run(sleep: RecordingSleeper().sleep) }
        defer { run.cancel() }
        try await waitUntil { await connection.transcriptFollowOpenings.count == 1 }
        let shown = model.items.count

        await connection.send(.appended(Self.addedChunk), toFollow: 0)
        try await waitUntil { await MainActor.run { model.items.count == shown + 1 } }
        await connection.send(.replaced(size: Self.size), toFollow: 0)
        try await waitUntil { await connection.transcriptFollowOpenings.count == 2 }

        #expect(await Self.windowReads(connection) == 2)
        #expect(await connection.transcriptFollowOpenings.last == TranscriptFollowOpening(path: Self.path, cursor: Self.size))
        #expect(await Self.tailReads(connection) == 0)
    }
}
