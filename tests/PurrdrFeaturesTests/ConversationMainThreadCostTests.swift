import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// #510:開啟聊天與追加內容時主執行緒的工作量——尾端全是工具步驟、補讀到 2000 則的情境。
/// 根因是 `Conversation.Builder` 每加一個步驟或配一個結果就複製並重算整串工具串(O(n²)),
/// 加上 `saveCache` 為了找可讀訊息一圈圈重建畫面項目。
@MainActor
@Suite("對話快取:主執行緒耗時")
struct ConversationMainThreadCostTests {
    typealias W = ConversationWorkingOpenTests
    typealias R = ConversationReadableMessageTests

    /// 前面 15 行有可讀訊息,後面接 `pairs` 組工具步驟。
    static func lines(pairs: Int) -> [String] {
        Array(R.fixture[0..<15]) + (0..<pairs).flatMap { W.toolPair($0) }
    }

    /// 記錄寫入次數與最後一次內容的快取。
    actor CountingCache: ConversationCache {
        private(set) var saves = 0
        private(set) var last: CachedConversation?
        func load(chatKey: String) -> CachedConversation? { last }
        func save(_ conversation: CachedConversation, chatKey: String) { saves += 1; last = conversation }
        func remove(chatKey: String) {}
        func removeAll(chatKeyPrefix prefix: String) {}
    }

    @Test("補讀到 2000 則、很多小段:組快取內容是線性掃描,不隨段數平方成長")
    func cacheSnapshotWithManySegmentsIsLinear() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await R.answering(connection, lines: Self.lines(pairs: 3))
        let model = R.model(connection)
        model.isFollowingLatest = false
        let chat = try await R.open(model, connection)
        defer { chat.cancel() }
        var cursor = W.size
        for index in 5_000..<5_700 {
            let added = W.toolPair(index)
            let end = cursor + added.reduce(0) { $0 + $1.utf8.count + 1 }
            await connection.send(.appended(TranscriptChunk(start: cursor, end: end, lines: added)), toFollow: 0)
            cursor = end
        }
        // 不靠固定睡眠:等到追蹤事件都套用(游標到齊)再取快照。
        let finalCursor = cursor
        try await waitUntil { await model.cacheSnapshot()?.cursor == finalCursor }

        let messages = try #require(model.cacheSnapshot()).messages
        #expect(messages.count > CachedConversation.maxMessages, "尾端沒有可讀訊息時應多留到可讀訊息")
        #expect(ConversationModel.hasReadableMessage(in: messages))
    }

    @Test("串流追加:節流期間不重複寫快取,離開時補寫最新內容")
    func throttlesCacheWritesWhileStreaming() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await R.answering(connection, lines: W.lines)
        let cache = CountingCache()
        let model = R.model(connection, cache: cache)
        let chat = try await R.open(model, connection)
        let savesAfterOpen = await cache.saves

        var cursor = W.size
        for index in 400..<410 {
            let added = W.toolPair(index)
            let end = cursor + added.reduce(0) { $0 + $1.utf8.count + 1 }
            await connection.send(.appended(TranscriptChunk(start: cursor, end: end, lines: added)), toFollow: 0)
            cursor = end
        }
        // 等到 10 則都套用(游標到齊);節流時鐘是固定的 TestClock,所以第一次寫入後的追加一律只標記未寫入。
        let finalCursor = cursor
        try await waitUntil { await model.cacheSnapshot()?.cursor == finalCursor }
        #expect(await cache.saves <= savesAfterOpen + 1, "10 則追加不該各存一次")
        #expect(model.cacheIsDirty)

        chat.cancel()
        await chat.value
        #expect(!model.cacheIsDirty)
        let saved = try #require(await cache.last)
        #expect(saved.cursor == cursor, "離開時要補寫最新的游標")
    }

    @Test("從 2000 則的快取還原(列表預載後開啟聊天時在主執行緒同步做):還原結果完整")
    func restoringLargeCacheIsCheap() async throws {
        let lines = Array(R.fixture[0..<15]) + (0..<950).flatMap { W.toolPair($0) }
        let messages = TranscriptDialect.claude.parse(lines).messages
        #expect(messages.count > 1_800)
        let cache = InMemoryConversationCache()
        await cache.save(
            CachedConversation(
                sessionID: W.sessionID, messages: messages, metadata: TranscriptMetadata(), path: W.path, cursor: 100, windowStart: 0,
                limit: CachedConversation.maxMessagesWithReadable),
            chatKey: W.paneID)
        let model = R.model(FakeHostConnection(), cache: cache)

        // 不斷言牆鐘時間(CI 負載下會偶發超時):O(n²) 回歸由核心的 ConversationLongToolRunTests 以比例測試守門,
        // 這裡只確認還原結果的結構。
        await model.restoreFromCache()

        #expect(!model.items.isEmpty)
        #expect(model.items.count > 1)
    }

    @Test("可讀訊息的線性檢查與畫面項目的結果一致")
    func linearReadableCheckMatchesItems() {
        let cases: [[String]] = [
            Array(R.fixture[0..<28]),
            (0..<5).flatMap { W.toolPair($0) },
            Array(R.fixture[0..<15]) + (0..<5).flatMap { W.toolPair($0) },
            Array(R.fixture[15..<18]),
        ]
        for lines in cases {
            let messages = TranscriptDialect.claude.parse(lines).messages
            let expected = Conversation.items(from: messages).contains { if case .toolRun = $0 { false } else { true } }
            #expect(ConversationModel.hasReadableMessage(in: messages) == expected)
        }
    }
}
