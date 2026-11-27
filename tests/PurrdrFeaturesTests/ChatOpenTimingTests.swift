import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 收集計時(可從任何執行緒呼叫)。
final class ChatOpenTimingCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OperationTiming] = []
    var timings: [OperationTiming] { lock.withLock { items } }
    var names: [String] { timings.map(\.name) }
    lazy var sink: OperationTimingSink = { [unowned self] timing in self.lock.withLock { self.items.append(timing) } }
}

/// #659:點進聊天的各步驟計時(只有名稱、毫秒與成敗),量出空等的時間花在哪。
@MainActor
@Suite("點進聊天的步驟計時")
struct ChatOpenTimingTests {
    typealias W = ConversationWorkingOpenTests
    typealias R = ConversationReadableMessageTests

    static func model(
        _ connection: FakeHostConnection, cache: any ConversationCache = InMemoryConversationCache(),
        session: String? = W.sessionID, timings: OperationTimingSink?
    ) -> ConversationModel {
        ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: W.paneID,
            knownSessionID: session, cache: cache, clock: TestClock().clock, links: .init(operationTimings: timings))
    }

    @Test("開啟並補讀好幾頁:快取未命中、快照、定位、視窗、逐頁補讀、第一次可讀,依序記下")
    func recordsEachStepInOrder() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await R.answering(connection, lines: W.lines)
        let collector = ChatOpenTimingCollector()
        let model = Self.model(connection, timings: collector.sink)
        let chat = try await R.open(model, connection)
        defer { chat.cancel() }

        let pages = await R.windowRequests(connection) - 1
        #expect(pages >= 2, "這份紀錄要補讀兩頁以上才有意義")
        let expected = ["chatOpen.cache miss", "chatOpen.snapshot", "chatOpen.locate", "chatOpen.window"]
            + (1...pages).map { "chatOpen.earlier#\($0)" } + ["chatOpen.firstReadable"]
        #expect(collector.names.filter { $0.hasPrefix("chatOpen.") } == expected)
        #expect(collector.timings.allSatisfy { !$0.failed && $0.milliseconds >= 0 })
    }

    @Test("快取命中且採用:記 hit 與 used")
    func cacheUsed() async throws {
        let connection = FakeHostConnection()
        let cache = InMemoryConversationCache()
        await cache.save(CachedConversation(
            sessionID: W.sessionID, messages: [], metadata: TranscriptMetadata(), path: W.path, cursor: W.size, windowStart: 0), chatKey: W.paneID)
        let collector = ChatOpenTimingCollector()
        let model = Self.model(connection, cache: cache, timings: collector.sink)
        await model.restoreFromCache()

        #expect(collector.names == ["chatOpen.cache hit", "chatOpen.cache used"])
    }

    @Test("快取命中但 session 戳記不符:記 hit 與 rejected session")
    func cacheRejectedForSession() async throws {
        let connection = FakeHostConnection()
        let cache = InMemoryConversationCache()
        await cache.save(CachedConversation(
            sessionID: "other", messages: [], metadata: TranscriptMetadata(), path: W.path, cursor: 0, windowStart: 0), chatKey: W.paneID)
        let collector = ChatOpenTimingCollector()
        let model = Self.model(connection, cache: cache, timings: collector.sink)
        await model.restoreFromCache()

        #expect(collector.names == ["chatOpen.cache hit", "chatOpen.cache rejected session"])
    }

    @Test("快取命中但尾端沒有可讀訊息:記 hit 與 rejected content")
    func cacheRejectedForContent() async throws {
        let toolOnly = AgentCatalog.profile(for: .claude).transcript!.parse((0..<3).flatMap { W.toolPair($0) })
        #expect(!toolOnly.messages.isEmpty)
        let connection = FakeHostConnection()
        let cache = InMemoryConversationCache()
        await cache.save(CachedConversation(
            sessionID: W.sessionID, messages: toolOnly.messages, metadata: TranscriptMetadata(), path: W.path, cursor: 0, windowStart: 0),
            chatKey: W.paneID)
        let collector = ChatOpenTimingCollector()
        let model = Self.model(connection, cache: cache, timings: collector.sink)
        await model.restoreFromCache()

        #expect(collector.names == ["chatOpen.cache hit", "chatOpen.cache rejected content"])
    }

    @Test("讀取失敗的步驟標記失敗,也不會記第一次可讀")
    func failedStepIsMarked() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await connection.serveTranscript(.init(locate: { _ in throw TranscriptReadError.unreadable }))
        let collector = ChatOpenTimingCollector()
        let model = Self.model(connection, timings: collector.sink)
        await model.poll()

        #expect(collector.timings.first { $0.name == "chatOpen.locate" }?.failed == true)
        #expect(!collector.names.contains("chatOpen.firstReadable"))
    }

    @Test("沒接計時時行為不變:一樣讀到可讀訊息")
    func noSinkNoChange() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await R.answering(connection, lines: W.lines)
        let model = Self.model(connection, timings: nil)
        let chat = try await R.open(model, connection)
        defer { chat.cancel() }
        #expect(W.hasReadableMessage(model.items))
    }
}
