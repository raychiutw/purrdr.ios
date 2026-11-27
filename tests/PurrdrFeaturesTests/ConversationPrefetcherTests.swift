import Foundation
@testable import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 連上主機後背景預讀聊天進快取(#663):排程、限流與寫入快取的規則。
@MainActor
@Suite("背景預讀聊天")
struct ConversationPrefetcherTests {
    static func candidate(_ pane: String, session: String = TranscriptFeedTests.sessionID, signature: String = "done") -> ConversationPrefetcher.Candidate {
        .init(route: ChatRoute(host: .demo, paneID: pane), target: TranscriptFeedTests.target(session: session), signature: signature)
    }

    @MainActor final class Reads {
        var panes: [String] = []
    }

    static func prefetcher(
        _ reads: Reads, limit: Int = 4, cellularLimit: Int = 0, cellular: Bool = false, blocked: Set<String> = []
    ) -> ConversationPrefetcher {
        ConversationPrefetcher(
            limit: limit, cellularLimit: cellularLimit, isCellular: { cellular },
            isBlocked: { blocked.contains($0.paneID) },
            read: { reads.panes.append($0.route.paneID); return true })
    }

    @Test("預讀把聊天讀進快取,之後打開聊天由快取先顯示(不再開追蹤)")
    func prefetchWritesCache() async throws {
        let connection = FakeHostConnection()
        await connection.serveTranscript(.init(
            locate: { _ in TranscriptFile(path: TranscriptFeedTests.path, size: TranscriptFeedTests.size) },
            window: { _, _, _, _ in TranscriptChunk(start: 0, end: TranscriptFeedTests.size, lines: TranscriptFeedTests.lines) },
            tail: { _, _, _, _ in throw FakeHostConnectionError.unsupported }))
        let cache = InMemoryConversationCache()
        let candidate = Self.candidate("w1:p6")

        let ok = await ConversationPrefetcher.read(candidate, reader: TranscriptReader(connection: connection), cache: HostScopedConversationCache(base: cache, scope: "demo"))

        #expect(ok)
        let saved = try #require(await cache.load(chatKey: "demo/w1:p6"))
        #expect(saved.matches(sessionID: TranscriptFeedTests.sessionID))
        #expect(!saved.messages.isEmpty)
        #expect(await connection.transcriptFollowOpenings.isEmpty)
    }

    @Test("沒有可讀訊息的尾端不寫進快取(#473)")
    func unreadableTailIsNotCached() async throws {
        let connection = FakeHostConnection()
        let toolOnly = Array(TranscriptFeedTests.lines.filter { $0.contains("\"tool_use\"") }.prefix(2))
        #expect(!toolOnly.isEmpty)
        await connection.serveTranscript(.init(
            locate: { _ in TranscriptFile(path: TranscriptFeedTests.path, size: 10) },
            window: { _, _, _, _ in TranscriptChunk(start: 0, end: 10, lines: toolOnly) },
            tail: { _, _, _, _ in throw FakeHostConnectionError.unsupported }))
        let cache = InMemoryConversationCache()

        _ = await ConversationPrefetcher.read(Self.candidate("w1:p6"), reader: TranscriptReader(connection: connection), cache: cache)

        #expect(await cache.load(chatKey: "w1:p6") == nil)
    }

    @Test("數量有上限:只讀前 N 個")
    func limitsCount() async {
        let reads = Reads()
        await Self.prefetcher(reads, limit: 2).prefetch(["a", "b", "c"].map { Self.candidate($0) })
        #expect(reads.panes == ["a", "b"])
    }

    @Test("行動網路下不預讀;給了行動網路上限就照上限")
    func cellular() async {
        let reads = Reads()
        await Self.prefetcher(reads, cellular: true).prefetch(["a", "b"].map { Self.candidate($0) })
        #expect(reads.panes.isEmpty)
        await Self.prefetcher(reads, cellularLimit: 1, cellular: true).prefetch(["a", "b"].map { Self.candidate($0) })
        #expect(reads.panes == ["a"])
    }

    @Test("有變化才讀:狀態沒變不重讀,變了才讀")
    func readsOnlyOnChange() async {
        let reads = Reads()
        let prefetcher = Self.prefetcher(reads)
        await prefetcher.prefetch([Self.candidate("a")])
        await prefetcher.prefetch([Self.candidate("a")])
        #expect(reads.panes == ["a"])
        await prefetcher.prefetch([Self.candidate("a", signature: "working")])
        #expect(reads.panes == ["a", "a"])
    }

    @Test("前景正在看的聊天不預讀")
    func skipsBlocked() async {
        let reads = Reads()
        await Self.prefetcher(reads, blocked: ["a"]).prefetch(["a", "b"].map { Self.candidate($0) })
        #expect(reads.panes == ["b"])
    }

    @Test("取消後不再讀下一個")
    func cancellable() async {
        let reads = Reads()
        let prefetcher = ConversationPrefetcher(read: { reads.panes.append($0.route.paneID); return true })
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await prefetcher.prefetch(["a", "b"].map { Self.candidate($0) })
        }
        await task.value
        #expect(reads.panes.isEmpty)
    }

    @Test("讀失敗不記成已讀,下次再試")
    func failureRetries() async {
        let reads = Reads()
        let prefetcher = ConversationPrefetcher(read: { reads.panes.append($0.route.paneID); return false })
        await prefetcher.prefetch([Self.candidate("a")])
        await prefetcher.prefetch([Self.candidate("a")])
        #expect(reads.panes == ["a", "a"])
    }
}
