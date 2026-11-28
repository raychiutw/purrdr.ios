import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 對話紀錄來源(`TranscriptFeed`,#684):直接以假的主機連線測來源本身——開啟、往前補讀、跟隨、修剪、
/// 換 session、丟掉過期讀取、快取還原與寫入。聊天 model 只負責把交出的增量套到時間軸。
@MainActor
@Suite("對話紀錄來源")
struct TranscriptFeedTests {
    nonisolated static let sessionID = "00000000-0000-0000-0000-000000000001"
    nonisolated static let path = "/Users/demo/.claude/projects/-Users-demo-Projects-garden-journal/\(sessionID).jsonl"
    nonisolated static let lines = Fixtures.transcriptLines()
    nonisolated static let size = lines.reduce(0) { $0 + $1.utf8.count + 1 }

    static func target(session: String = sessionID) -> TranscriptTarget {
        let dialect = TranscriptDialect.claude
        return TranscriptTarget(
            dialect: dialect, location: dialect.location(kind: "id", value: session, cwd: "/Users/demo/Projects/garden-journal")!,
            sessionKey: session)
    }

    /// 收下來源交出的事件。
    @MainActor
    final class Recorder {
        var events: [TranscriptFeed.Event] = []
        var deltas: [TranscriptDelta] {
            events.compactMap { if case .delta(let delta) = $0 { delta } else { nil } }
        }
    }

    struct Setup {
        let feed: TranscriptFeed
        let connection: FakeHostConnection
        let recorder: Recorder
        let cache: InMemoryConversationCache
    }

    /// 視窗回整個 fixture(起點 0);`window` 可換成自己的回應。
    static func setup(
        openLines: Int = 40, pageLines: Int = 200, knownSession: String? = sessionID,
        window: (@Sendable (String, Int, Int, Int) throws -> TranscriptChunk)? = nil,
        cache: InMemoryConversationCache = InMemoryConversationCache()
    ) async -> Setup {
        let connection = FakeHostConnection()
        await connection.serveTranscript(.init(
            locate: { _ in TranscriptFile(path: path, size: size) },
            window: window ?? { _, _, _, _ in TranscriptChunk(start: 0, end: size, lines: lines) },
            tail: { _, cursor, _, _ in
                guard cursor == TranscriptReader.probeCursor else { throw FakeHostConnectionError.unsupported }
                return TranscriptTailRead(tail: .shrank(size: size), size: size)
            }))
        let recorder = Recorder()
        let feed = TranscriptFeed(
            reader: TranscriptReader(connection: connection), cache: cache, chatKey: "w1:p6", knownSessionID: knownSession,
            clock: TestClock().clock, readLimits: { TranscriptReadLimits(openLines: openLines, maxBytes: 0, emptyWindowBackfillPages: 25) }, pageLines: pageLines, timings: nil, onSkips: nil)
        feed.onEvent = { recorder.events.append($0) }
        return Setup(feed: feed, connection: connection, recorder: recorder, cache: cache)
    }

    @Test("沒綁 Agent 前沒有方言，不預設成 Claude")
    func noDialectUntilBound() async throws {
        let setup = await Self.setup()
        #expect(setup.feed.dialect == nil)
        _ = await setup.feed.bind(to: Self.target())
        #expect(setup.feed.dialect == .claude)
    }

    @Test("開啟:讀檔尾，交出整份換掉的增量(訊息、metadata、older 都在增量裡)")
    func openReadsTailAndHandsOverReplacement() async throws {
        let setup = await Self.setup()
        let target = Self.target()
        #expect(await setup.feed.bind(to: target))

        let result = await setup.feed.read(target)

        #expect(result == .caughtUp)
        #expect(setup.feed.path == Self.path)
        let delta = try #require(setup.recorder.deltas.first)
        guard case .rebuild(let messages) = delta.timeline else { Issue.record("要整份換掉"); return }
        #expect(!messages.isEmpty)
        #expect(delta.older == .reachedStart)
        #expect(setup.feed.messages.count == messages.count)
    }

    @Test("往前補讀:交出往上補的增量，到起點變成 reachedStart")
    func loadOlderHandsOverPrepend() async throws {
        let chunkStart = 100
        let setup = await Self.setup(window: { _, end, _, _ in
            end == Self.size
                ? TranscriptChunk(start: chunkStart, end: end, lines: Array(Self.lines.suffix(4)))
                : TranscriptChunk(start: 0, end: end, lines: Array(Self.lines.prefix(4)))
        })
        let target = Self.target()
        _ = await setup.feed.bind(to: target)
        _ = await setup.feed.read(target)
        #expect(setup.feed.older == .available)
        let before = setup.recorder.deltas.count

        await setup.feed.loadOlder()

        let added = Array(setup.recorder.deltas.dropFirst(before))
        let last = try #require(added.last)
        guard case .prepend(let page) = last.timeline else { Issue.record("要往上補"); return }
        #expect(!page.isEmpty)
        #expect(last.older == .reachedStart)
        #expect(setup.feed.olderMessages.count == page.count)
    }

    @Test("跟隨最新:追蹤送來的新內容交出新增的增量，超過上限時一併交出修剪數")
    func followAppendsAndTrims() async throws {
        let setup = await Self.setup()
        let target = Self.target()
        _ = await setup.feed.bind(to: target)
        setup.feed.followPace = TranscriptFollowPace(interval: .seconds(2), sleep: RecordingSleeper().sleep)
        _ = await setup.feed.read(target)
        let shown = setup.feed.messages.count
        try await waitUntil { await setup.connection.transcriptFollowOpenings.count == 1 }

        let line = ConversationCatchUpTests.userLine(1, bytes: 30)
        await setup.connection.send(.appended(TranscriptChunk(start: Self.size, end: Self.size + line.utf8.count + 1, lines: [line])), toFollow: 0)
        try await waitUntil { await MainActor.run { setup.feed.messages.count == shown + 1 } }

        guard case .append(let added, let dropped)? = setup.recorder.deltas.last?.timeline else { Issue.record("要新增"); return }
        #expect(added.count == 1)
        #expect(dropped == nil)
        setup.feed.stopFollowing()
    }

    @Test("修剪:跟隨最新且超過上限時丟掉最舊的整段;不跟隨時不修剪")
    func trimsOnlyWhenFollowingLatest() async throws {
        let limit = TranscriptFeed.followingMessageLimit
        let setup = await Self.setup()
        let target = Self.target()
        _ = await setup.feed.bind(to: target)
        _ = await setup.feed.read(target)
        // 灌到超過上限:每段 100 則訊息，各是不同的 byte 範圍。
        func chunk(_ index: Int, count: Int) -> TranscriptChunk {
            let batch = (0..<count).map { ConversationCatchUpTests.userLine(index * 1000 + $0, bytes: 30) }
            let start = Self.size + index * 100_000
            return TranscriptChunk(start: start, end: start + 100_000, lines: batch)
        }
        setup.feed.isFollowingLatest = false
        for index in 0..<(limit / 100 + 2) { await setup.feed.append(chunk(index, count: 100)) }
        #expect(setup.feed.messages.count > limit)
        let untrimmed = setup.feed.messages.count

        setup.feed.isFollowingLatest = true
        await setup.feed.append(chunk(99, count: 1))

        #expect(setup.feed.messages.count < untrimmed)
        guard case .append(_, let dropped)? = setup.recorder.deltas.last?.timeline else { Issue.record("要新增"); return }
        #expect((dropped ?? 0) > 0)
        #expect(setup.feed.messages.count <= limit + 100)
    }

    @Test("換 session:過期的讀取在來源內部丟掉，不交出增量也不寫入")
    func supersededReadIsDropped() async throws {
        let setup = await Self.setup()
        await setup.connection.holdTranscripts()
        let target = Self.target()
        _ = await setup.feed.bind(to: target)
        let inFlight = Task { await setup.feed.read(target) }
        try await waitUntil { await setup.connection.heldTranscriptCount == 1 }

        let other = Self.target(session: "00000000-0000-0000-0000-000000000002")
        #expect(await setup.feed.bind(to: other))
        await setup.connection.releaseTranscripts()
        let result = await inFlight.value

        #expect(result == .superseded)
        #expect(setup.recorder.deltas.isEmpty)
        #expect(setup.feed.messages.isEmpty)
        #expect(setup.feed.path == nil)
        #expect(await setup.cache.load(chatKey: "w1:p6") == nil)
    }

    @Test("換 session:過期的讀取就算失敗也算過期,不回報讀取失敗")
    func supersededFailureIsNotReported() async throws {
        let connection = FakeHostConnection()
        await connection.serveTranscript(.init(
            locate: { _ in throw FakeHostConnectionError.unsupported },
            window: { _, _, _, _ in throw FakeHostConnectionError.unsupported },
            tail: { _, _, _, _ in throw FakeHostConnectionError.unsupported }))
        await connection.holdTranscripts()
        let feed = TranscriptFeed(
            reader: TranscriptReader(connection: connection), cache: InMemoryConversationCache(), chatKey: "w1:p6", knownSessionID: nil,
            clock: TestClock().clock, readLimits: { TranscriptReadLimits(openLines: 40, maxBytes: 0, emptyWindowBackfillPages: 25) }, pageLines: 200, timings: nil, onSkips: nil)
        let target = Self.target()
        _ = await feed.bind(to: target)
        let inFlight = Task { await feed.read(target) }
        try await waitUntil { await connection.heldTranscriptCount == 1 }

        _ = await feed.bind(to: Self.target(session: "00000000-0000-0000-0000-000000000002"))
        await connection.releaseTranscripts()

        #expect(await inFlight.value == .superseded)
    }

    @Test("讀取失敗:交給聊天顯示;找不到檔案時來源自己放掉檔案")
    func readFailureIsReported() async throws {
        let connection = FakeHostConnection()
        await connection.serveTranscript(.init(
            locate: { _ in throw TranscriptReadError.absent },
            window: { _, _, _, _ in throw FakeHostConnectionError.unsupported },
            tail: { _, _, _, _ in throw FakeHostConnectionError.unsupported }))
        let feed = TranscriptFeed(
            reader: TranscriptReader(connection: connection), cache: InMemoryConversationCache(), chatKey: "w1:p6", knownSessionID: nil,
            clock: TestClock().clock, readLimits: { TranscriptReadLimits(openLines: 40, maxBytes: 0, emptyWindowBackfillPages: 25) }, pageLines: 200, timings: nil, onSkips: nil)
        let target = Self.target()
        _ = await feed.bind(to: target)

        let result = await feed.read(target)

        guard case .failed(let error) = result, case TranscriptReadError.absent = error else { Issue.record("要回報找不到"); return }
        #expect(feed.path == nil)
    }

    @Test("快取:讀完寫入,同 session 的新來源還原並交出整份換掉;別的 session 或沒有可讀訊息不還原")
    func cacheRoundTrip() async throws {
        let cache = InMemoryConversationCache()
        let first = await Self.setup(cache: cache)
        let target = Self.target()
        _ = await first.feed.bind(to: target)
        _ = await first.feed.read(target)
        #expect(await cache.load(chatKey: "w1:p6") != nil)

        let second = await Self.setup(cache: cache)
        #expect(await second.feed.restoreFromCache())
        #expect(second.feed.boundSessionID == Self.sessionID)
        #expect(second.feed.path == Self.path)
        guard case .rebuild(let messages)? = second.recorder.deltas.last?.timeline else { Issue.record("要整份換掉"); return }
        #expect(!messages.isEmpty)

        let stranger = await Self.setup(knownSession: "other", cache: cache)
        #expect(await stranger.feed.restoreFromCache() == false)
        #expect(stranger.recorder.deltas.isEmpty)
    }

    @Test("快取寫入有節流:追蹤事件間隔內只記髒,flush 才補寫")
    func cacheWriteIsThrottled() async throws {
        let cache = InMemoryConversationCache()
        let setup = await Self.setup(cache: cache)
        let target = Self.target()
        _ = await setup.feed.bind(to: target)
        _ = await setup.feed.read(target)
        await cache.remove(chatKey: "w1:p6")

        await setup.feed.saveCacheThrottled()
        #expect(await cache.load(chatKey: "w1:p6") == nil)
        #expect(setup.feed.cacheIsDirty)

        await setup.feed.flushCache()
        #expect(await cache.load(chatKey: "w1:p6") != nil)
        #expect(setup.feed.cacheIsDirty == false)
    }
}
