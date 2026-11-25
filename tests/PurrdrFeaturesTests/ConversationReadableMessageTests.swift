import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// #473:開啟聊天時「可讀訊息」的定義(使用者訊息、Agent 文字、備註、skill、subagent、shell…都算,只有摺起來的工具步驟不算)、
/// 補讀上限、已完成的聊天不多讀、follow 追加不丟補讀內容、快取尾端沒有可讀訊息就不還原。
@MainActor
@Suite("對話開啟:可讀訊息")
struct ConversationReadableMessageTests {
    typealias W = ConversationWorkingOpenTests

    /// 依 `lines` 回應主機腳本的對話紀錄請求。
    static func answering(_ connection: FakeHostConnection, lines: [String]) async {
        let offsets = lines.reduce(into: [0]) { $0.append($0.last! + $1.utf8.count + 1) }
        let size = offsets.last!
        await connection.serveTranscript(.init(
            locate: { _ in TranscriptFile(path: W.path, size: size) },
            window: { _, end, count, maxBytes in
                let last = offsets.lastIndex { $0 <= end }!
                var first = max(0, last - count)
                while maxBytes > 0, first < last - 1, offsets[last] - offsets[first] > maxBytes { first += 1 }
                return TranscriptChunk(start: offsets[first], end: offsets[last], lines: Array(lines[first..<last]))
            },
            tail: { _, cursor, _, _ in
                guard cursor == TranscriptReader.probeCursor else { throw FakeHostConnectionError.unsupported }
                return TranscriptTailRead(tail: .shrank(size: size), size: size)
            }))
    }

    static func model(_ connection: FakeHostConnection, cache: any ConversationCache = InMemoryConversationCache()) -> ConversationModel {
        ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: W.paneID,
            knownSessionID: W.sessionID, cache: cache, clock: TestClock().clock)
    }

    static func windowRequests(_ connection: FakeHostConnection) async -> Int {
        await connection.transcriptWindowReads.count
    }

    /// 開啟後等到第一輪讀取結束(追蹤已開)。
    static func open(_ model: ConversationModel, _ connection: FakeHostConnection) async throws -> Task<Void, Never> {
        let chat = Task { await model.run(sleep: RecordingSleeper().sleep) }
        try await waitUntil { await connection.transcriptFollowOpenings.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        return chat
    }

    nonisolated static let fixture = Fixtures.transcriptLines()

    @Test("尾端是 skill 卡加一串工具步驟:skill 卡算可讀訊息,不為了找使用者／Agent 文字多讀")
    func skillCardCountsAsReadable() async throws {
        // fixture 第 15–17 行是 Skill 呼叫、結果與載入;前面 15 行有使用者與 Agent 文字,中間接很多工具步驟,最後是 skill。
        let lines = Array(Self.fixture[0..<15]) + (0..<60).flatMap { W.toolPair($0) } + Array(Self.fixture[15...17])
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await Self.answering(connection, lines: lines)
        let model = Self.model(connection)
        let chat = try await Self.open(model, connection)
        defer { chat.cancel() }

        #expect(model.items.contains { if case .skill = $0 { true } else { false } })
        #expect(await Self.windowRequests(connection) == 1, "尾端已有 skill 卡,不該再往前補讀")
    }

    @Test("已完成的聊天(尾端是 Agent 文字):只讀一個視窗,不多讀")
    func finishedChatReadsOneWindow() async throws {
        let lines = Array(Self.fixture[0..<28])
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await Self.answering(connection, lines: lines)
        let model = Self.model(connection)
        let chat = try await Self.open(model, connection)
        defer { chat.cancel() }

        #expect(await Self.windowRequests(connection) == 1)
    }

    @Test("整份紀錄都是工具步驟:補讀有頁數上限,不會無止境下載")
    func backfillIsBounded() async throws {
        let lines = (0..<1_500).flatMap { W.toolPair($0) }
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await Self.answering(connection, lines: lines)
        let model = Self.model(connection)
        let chat = try await Self.open(model, connection)
        defer { chat.cancel() }

        #expect(await Self.windowRequests(connection) <= 1 + ConversationModel.maximumEmptyWindowPages + 1)
    }

    @Test("補讀回來的可讀訊息:follow 持續追加工具步驟也不會被丟掉")
    func followAppendsKeepBackfilledMessages() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await Self.answering(connection, lines: W.lines)
        let model = Self.model(connection)
        let chat = try await Self.open(model, connection)
        defer { chat.cancel() }
        #expect(W.hasReadableMessage(model.items))

        var cursor = W.size
        for index in 300..<306 {
            let added = W.toolPair(index)
            let end = cursor + added.reduce(0) { $0 + $1.utf8.count + 1 }
            await connection.send(.appended(TranscriptChunk(start: cursor, end: end, lines: added)), toFollow: 0)
            cursor = end
        }
        try await Task.sleep(for: .milliseconds(300))

        #expect(W.hasReadableMessage(model.items), "追加工具步驟後補讀的訊息不見了")
    }

    @Test("快取尾端沒有可讀訊息:視為沒有可用快取,不還原只有工具步驟的畫面")
    func toolOnlyCacheIsNotRestored() async throws {
        let cache = InMemoryConversationCache()
        let messages = TranscriptDialect.claude.parse((0..<5).flatMap { W.toolPair($0) }).messages
        #expect(!messages.isEmpty)
        await cache.save(
            CachedConversation(sessionID: W.sessionID, messages: messages, metadata: TranscriptMetadata(), path: W.path, cursor: 100, windowStart: 0),
            chatKey: W.paneID)
        let model = Self.model(FakeHostConnection(), cache: cache)

        await model.restoreFromCache()

        #expect(model.items.isEmpty)
        #expect(model.phase == .loading)
    }

    @Test("快取有可讀訊息:照常還原")
    func readableCacheIsRestored() async throws {
        let cache = InMemoryConversationCache()
        let messages = TranscriptDialect.claude.parse(Array(Self.fixture[0..<28])).messages
        await cache.save(
            CachedConversation(sessionID: W.sessionID, messages: messages, metadata: TranscriptMetadata(), path: W.path, cursor: 100, windowStart: 0),
            chatKey: W.paneID)
        let model = Self.model(FakeHostConnection(), cache: cache)

        await model.restoreFromCache()

        #expect(W.hasReadableMessage(model.items))
    }

    // MARK: - #508:開啟工作中的聊天,尾端大量工具步驟

    nonisolated static let longToolTail: [String] = Fixtures.transcriptLines() + (0..<500).flatMap { W.toolPair($0) }

    @Test("#508 尾端一千行都是工具步驟:補讀往返次數要少(逐頁 200 行會讀 6 次,每次往返都是使用者等待)")
    func backfillNeedsFewRoundTrips() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await Self.answering(connection, lines: Self.longToolTail)
        let model = Self.model(connection)
        let chat = try await Self.open(model, connection)
        defer { chat.cancel() }

        #expect(W.hasReadableMessage(model.items))
        let requests = await Self.windowRequests(connection)
        #expect(requests <= 4, "window 請求 \(requests) 次")
    }

    @Test("#508 補讀出的可讀訊息寫進快取:第二次開啟立刻有內容,不必再補讀")
    func backfilledMessagesArePersistedForNextOpen() async throws {
        let cache = InMemoryConversationCache()
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await Self.answering(connection, lines: Self.longToolTail)
        let first = Self.model(connection, cache: cache)
        let chat = try await Self.open(first, connection)
        chat.cancel()
        #expect(W.hasReadableMessage(first.items))

        let second = Self.model(FakeHostConnection(), cache: cache)
        await second.restoreFromCache()

        #expect(W.hasReadableMessage(second.items), "第二次開啟快取沒有可讀訊息")
    }

    @Test("#508 開啟補讀不當成往上翻:時間軸原因是整份取代(跟隨最新時維持在底部,不跳位置)")
    func backfillDoesNotReportOlderLoaded() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await Self.answering(connection, lines: Self.longToolTail)
        let model = Self.model(connection)
        var causes: [ConversationTimeline.Cause] = []
        model.onTimelineUpdate = { causes.append($0.cause) }
        let chat = try await Self.open(model, connection)
        defer { chat.cancel() }

        #expect(W.hasReadableMessage(model.items))
        #expect(!causes.contains(.olderLoaded), "causes \(causes)")
    }
}
