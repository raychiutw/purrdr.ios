import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import Testing

/// 對話快取的記憶體層(#487 補件):打開聊天時可以同步取得最近開過的聊天,不必等非同步的 SQLite。
@Suite("對話快取:記憶體層")
struct MemoryFrontedConversationCacheTests {
    static func conversation(session: String = "s1", cursor: Int = 10) -> CachedConversation {
        CachedConversation(sessionID: session, messages: [], metadata: TranscriptMetadata(), path: "/t.jsonl", cursor: cursor, windowStart: 0)
    }

    @Test("存進去後可以同步取得(不必 await)")
    func savedConversationIsAvailableSynchronously() async {
        let cache = MemoryFrontedConversationCache(base: InMemoryConversationCache())

        await cache.save(Self.conversation(), chatKey: "w1:p1")

        #expect(cache.cachedConversation(chatKey: "w1:p1") == Self.conversation())
        #expect(cache.cachedConversation(chatKey: "w1:p2") == nil)
    }

    @Test("預先載入:從底層讀過一次後,同步取得")
    func loadingFromBaseWarmsMemory() async {
        let base = InMemoryConversationCache()
        await base.save(Self.conversation(cursor: 42), chatKey: "w1:p1")
        let cache = MemoryFrontedConversationCache(base: base)
        #expect(cache.cachedConversation(chatKey: "w1:p1") == nil)

        let loaded = await cache.load(chatKey: "w1:p1")

        #expect(loaded?.cursor == 42)
        #expect(cache.cachedConversation(chatKey: "w1:p1")?.cursor == 42)
    }

    @Test("移除與依前綴移除:記憶體與底層同步清掉")
    func removalClearsMemoryAndBase() async {
        let base = InMemoryConversationCache()
        let cache = MemoryFrontedConversationCache(base: base)
        await cache.save(Self.conversation(), chatKey: "h1/w1:p1")
        await cache.save(Self.conversation(), chatKey: "h1/w1:p2")
        await cache.save(Self.conversation(), chatKey: "h2/w1:p1")

        await cache.remove(chatKey: "h1/w1:p1")
        #expect(cache.cachedConversation(chatKey: "h1/w1:p1") == nil)
        #expect(await base.load(chatKey: "h1/w1:p1") == nil)

        await cache.removeAll(chatKeyPrefix: "h1/")
        #expect(cache.cachedConversation(chatKey: "h1/w1:p2") == nil)
        #expect(cache.cachedConversation(chatKey: "h2/w1:p1") != nil)
    }

    @Test("依主機分開的快取把同步讀取轉給記憶體層,key 加上主機前綴")
    func hostScopedCacheForwardsSynchronousRead() async {
        let cache = MemoryFrontedConversationCache(base: InMemoryConversationCache())
        let scoped = HostScopedConversationCache(base: cache, scope: "host-a")

        await scoped.save(Self.conversation(), chatKey: "w1:p1")

        #expect(scoped.cachedConversation(chatKey: "w1:p1") != nil)
        #expect(cache.cachedConversation(chatKey: "host-a/w1:p1") != nil)
        #expect(HostScopedConversationCache(base: cache, scope: "host-b").cachedConversation(chatKey: "w1:p1") == nil)
    }

    @Test("沒有記憶體層的快取:同步讀取一律是 nil")
    func plainCacheHasNoSynchronousRead() async {
        let base = InMemoryConversationCache()
        await base.save(Self.conversation(), chatKey: "w1:p1")

        #expect(base.cachedConversation(chatKey: "w1:p1") == nil)
    }
}
