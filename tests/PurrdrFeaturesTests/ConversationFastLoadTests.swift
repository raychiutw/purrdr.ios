import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 聊天載入(#356):本機快取先顯示、第一次只讀一小段、讀 Pane 畫面不擋第一個畫面。
/// 網路慢用假連線的 `hold` 模擬;對話紀錄回放 `TranscriptFollowViewTests` 的 fixture。
@MainActor
@Suite("聊天載入：快取先顯示、短載入、讀畫面延後")
struct ConversationFastLoadTests {
    typealias Source = TranscriptFollowViewTests

    static func model(
        _ connection: FakeHostConnection, cache: any ConversationCache, knownSessionID: String? = Source.sessionID
    ) -> ConversationModel {
        ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Source.paneID,
            knownSessionID: knownSessionID, cache: cache, clock: TestClock().clock)
    }

    static func connection(extraExpectations: Int = 0) async -> FakeHostConnection {
        let connection = FakeHostConnection()
        for _ in 0..<(1 + extraExpectations) { await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson")) }
        await Source.answering(connection)
        return connection
    }

    /// 先在一條順暢的連線上讀完一次，讓 `cache` 有內容(像上一次開過這個聊天)。
    static func fillCache(_ cache: any ConversationCache) async {
        let connection = await Self.connection()
        let model = Self.model(connection, cache: cache)
        await model.poll()
        #expect(model.items.isEmpty == false)
    }

    /// 開聊天、快照卡住(網路很慢):回傳還沒完成的 run。
    static func openWithSlowSnapshot(
        cache: any ConversationCache, knownSessionID: String?
    ) async throws -> (model: ConversationModel, connection: FakeHostConnection, run: Task<Void, Never>) {
        let connection = await Self.connection()
        await connection.hold("session.snapshot")
        let model = Self.model(connection, cache: cache, knownSessionID: knownSessionID)
        let run = Task { await model.run(sleep: RecordingSleeper().sleep) }
        try await waitUntil { await connection.heldCount == 1 }
        return (model, connection, run)
    }

    // MARK: - 短載入

    @Test("第一次只讀最後 40 行、不超過 64 KiB(不是 300 行)")
    func firstWindowIsShort() async throws {
        let connection = await Self.connection()
        let model = Self.model(connection, cache: InMemoryConversationCache())

        await model.poll()

        let windows = await connection.transcriptRequests.compactMap { request -> (lines: Int, maxBytes: Int?)? in
            if case .window(_, _, let lines, _, let maxBytes) = request { (lines, maxBytes) } else { nil }
        }
        #expect(windows.count == 1)
        #expect(windows.first?.lines == 40)
        #expect(windows.first?.maxBytes == 64 << 10)
        #expect(TranscriptReader.openingLines == 40)
        #expect(TranscriptReader.openingMaxBytes == 64 << 10)
    }

    // MARK: - 讀畫面延後

    @Test("Pane 畫面還沒讀回來，對話已經顯示")
    func paneReadDoesNotBlockFirstScreen() async throws {
        let connection = await Self.connection()
        await connection.expect("pane.read", reply: Fixtures.data("pane.read.ansi.suggestion.ndjson"))
        await connection.hold("pane.read")
        let model = Self.model(connection, cache: InMemoryConversationCache())
        let run = Task { await model.run(sleep: RecordingSleeper().sleep) }
        defer { run.cancel() }

        try await waitUntil { await MainActor.run { model.items.isEmpty == false } }
        try await waitUntil { await connection.heldCount == 1 }

        #expect(model.items.isEmpty == false)
        await connection.releaseHeld()
    }

    // MARK: - 本機快取先顯示

    @Test("有快取、主機很慢：立刻顯示快取，不轉圈")
    func cacheHitShowsBeforeHostAnswers() async throws {
        let cache = InMemoryConversationCache()
        await Self.fillCache(cache)

        let open = try await Self.openWithSlowSnapshot(cache: cache, knownSessionID: Source.sessionID)
        defer { open.run.cancel() }

        #expect(open.model.items.isEmpty == false)
        #expect(open.model.phase == .ready)
    }

    @Test("有快取、但列表還沒給 session(推播冷啟動)：同樣立刻顯示快取")
    func cacheHitWithoutKnownSession() async throws {
        let cache = InMemoryConversationCache()
        await Self.fillCache(cache)

        let open = try await Self.openWithSlowSnapshot(cache: cache, knownSessionID: nil)
        defer { open.run.cancel() }

        #expect(open.model.items.isEmpty == false)
        #expect(open.model.phase == .ready)
    }

    @Test("沒有快取、主機很慢：還在載入，沒有內容(骨架佔位的情況)")
    func cacheMissWaitsForHost() async throws {
        let open = try await Self.openWithSlowSnapshot(cache: InMemoryConversationCache(), knownSessionID: Source.sessionID)
        defer { open.run.cancel() }

        #expect(open.model.items.isEmpty)
        #expect(open.model.phase == .loading)
    }

    @Test("快取的是別的 session：不顯示")
    func cacheOfAnotherSessionIsIgnored() async throws {
        let cache = InMemoryConversationCache()
        await Self.fillCache(cache)

        let open = try await Self.openWithSlowSnapshot(cache: cache, knownSessionID: "another-session")
        defer { open.run.cancel() }

        #expect(open.model.items.isEmpty)
    }

    @Test("冷啟動：上一次存進 SQLite 的對話，重開 app(新的資料庫實例、新的 model)立刻顯示")
    func coldStartShowsSQLiteCache() async throws {
        let file = SQLiteConversationCacheTests.temporaryFile()
        await Self.fillCache(SQLiteConversationCache(file: file))

        let open = try await Self.openWithSlowSnapshot(cache: SQLiteConversationCache(file: file), knownSessionID: nil)
        defer { open.run.cancel() }

        #expect(open.model.items.isEmpty == false)
        #expect(open.model.phase == .ready)
    }

    // MARK: - 打開時同步還原(記憶體層)

    @Test("記憶體層命中:model 建立完就有內容,不必 run、不必 await")
    func memoryHitRestoresSynchronouslyOnInit() async {
        let cache = MemoryFrontedConversationCache(base: InMemoryConversationCache())
        await Self.fillCache(cache)

        let model = Self.model(await Self.connection(), cache: cache)

        #expect(model.items.isEmpty == false)
        #expect(model.rows.isEmpty == false)
        #expect(model.phase == .ready)
    }

    @Test("記憶體層命中但 session 不符:不採用,還在載入")
    func memoryHitOfAnotherSessionIsIgnored() async {
        let cache = MemoryFrontedConversationCache(base: InMemoryConversationCache())
        await Self.fillCache(cache)

        let model = Self.model(await Self.connection(), cache: cache, knownSessionID: "another-session")

        #expect(model.items.isEmpty)
        #expect(model.phase == .loading)
    }

    @Test("寫入快取後記憶體層同步更新:同一個聊天再開一次直接有內容")
    func savingUpdatesMemoryLayer() async {
        let cache = MemoryFrontedConversationCache(base: InMemoryConversationCache())
        #expect(cache.cachedConversation(chatKey: Source.paneID) == nil)

        await Self.fillCache(cache)

        #expect(cache.cachedConversation(chatKey: Source.paneID) != nil)
    }

    // MARK: - 骨架延遲

    /// 開聊天、快照卡住,睡眠只讓 `loadingSkeletonDelay` 到期。
    static func openSlowSkeleton(delayElapses: Bool) async throws -> (model: ConversationModel, run: Task<Void, Never>, connection: FakeHostConnection) {
        let connection = await Self.connection()
        await connection.hold("session.snapshot")
        let model = Self.model(connection, cache: InMemoryConversationCache())
        let sleeper = RecordingSleeper { $0 == ConversationModel.loadingSkeletonDelay && delayElapses }
        let run = Task { await model.run(sleep: sleeper.sleep) }
        try await waitUntil { await connection.heldCount == 1 }
        if delayElapses { try await waitUntil { await MainActor.run { model.showsLoadingSkeleton } } }
        return (model, run, connection)
    }

    @Test("沒命中快取、還沒到 300 毫秒:不畫骨架")
    func noSkeletonBeforeDelay() async throws {
        let open = try await Self.openSlowSkeleton(delayElapses: false)
        defer { open.run.cancel() }

        #expect(open.model.phase == .loading)
        #expect(open.model.showsLoadingSkeleton == false)
    }

    @Test("沒命中快取、超過 300 毫秒仍沒有內容:畫骨架;內容一到就消失")
    func skeletonAppearsAfterDelayThenGoes() async throws {
        let open = try await Self.openSlowSkeleton(delayElapses: true)
        defer { open.run.cancel() }
        #expect(open.model.showsLoadingSkeleton)

        await open.connection.releaseHeld()
        try await waitUntil { await MainActor.run { open.model.items.isEmpty == false } }

        #expect(open.model.showsLoadingSkeleton == false)
    }

    // MARK: - 進度指示(HIG〈Loading〉:超過一兩秒才出現)

    /// 開聊天、快照卡住，睡眠只讓 `loadingIndicatorDelay` 到期(其他等待不到期)。
    static func openSlow(cache: any ConversationCache, delayElapses: Bool) async throws -> (model: ConversationModel, run: Task<Void, Never>, connection: FakeHostConnection) {
        let connection = await Self.connection()
        await connection.hold("session.snapshot")
        let model = Self.model(connection, cache: cache)
        let sleeper = RecordingSleeper { $0 == ConversationModel.loadingIndicatorDelay && delayElapses }
        let run = Task { await model.run(sleep: sleeper.sleep) }
        try await waitUntil { await connection.heldCount == 1 }
        if delayElapses { try await waitUntil { await MainActor.run { model.showsLoadingIndicator } } }
        return (model, run, connection)
    }

    @Test("沒有快取、還沒超過門檻：只有骨架，沒有進度指示")
    func noIndicatorBeforeThreshold() async throws {
        let open = try await Self.openSlow(cache: InMemoryConversationCache(), delayElapses: false)
        defer { open.run.cancel() }

        #expect(open.model.phase == .loading)
        #expect(open.model.showsLoadingIndicator == false)
    }

    @Test("沒有快取、超過門檻仍沒有內容：出現進度指示；內容一到就消失")
    func indicatorAppearsAfterThresholdThenGoes() async throws {
        let open = try await Self.openSlow(cache: InMemoryConversationCache(), delayElapses: true)
        defer { open.run.cancel() }
        #expect(open.model.showsLoadingIndicator)

        await open.connection.releaseHeld()
        try await waitUntil { await MainActor.run { open.model.items.isEmpty == false } }

        #expect(open.model.showsLoadingIndicator == false)
    }

    @Test("有快取：即使等待超過門檻也不出現進度指示")
    func noIndicatorWhenCached() async throws {
        let cache = InMemoryConversationCache()
        await Self.fillCache(cache)
        let connection = await Self.connection()
        await connection.hold("session.snapshot")
        let model = Self.model(connection, cache: cache)
        let sleeper = RecordingSleeper { $0 == ConversationModel.loadingIndicatorDelay }
        let run = Task { await model.run(sleep: sleeper.sleep) }
        defer { run.cancel() }
        try await waitUntil { await connection.heldCount == 1 }
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.items.isEmpty == false)
        #expect(model.showsLoadingIndicator == false)
    }
}
