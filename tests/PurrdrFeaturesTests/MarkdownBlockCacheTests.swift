import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 訊息 Markdown 解析結果快取(#498):同一則訊息內容沒變不重新解析。
@MainActor
@Suite("Markdown 解析快取")
struct MarkdownBlockCacheTests {
    @Test("同 id 同內容只解析一次，內容變了才重新解析")
    func parsesOncePerContent() {
        let cache = MarkdownBlockCache()
        let first = cache.blocks(id: "a1", markdown: "Hello **world**")
        #expect(cache.blocks(id: "a1", markdown: "Hello **world**") == first)
        #expect(cache.parseCount == 1)
        #expect(cache.blocks(id: "a1", markdown: "Hello **world**!") != first)
        #expect(cache.parseCount == 2)
    }

    @Test("超過上限丟最久沒用的")
    func evictsLeastRecentlyUsed() {
        let cache = MarkdownBlockCache(limit: 4)
        for index in 0..<4 { _ = cache.blocks(id: "m\(index)", markdown: "text \(index)") }
        _ = cache.blocks(id: "m3", markdown: "text 3")
        #expect(cache.parseCount == 4)
        _ = cache.blocks(id: "m4", markdown: "text 4")  // 超過上限:丟掉最久沒用的 m0
        #expect(cache.parseCount == 5)
        _ = cache.blocks(id: "m3", markdown: "text 3")
        #expect(cache.parseCount == 5)
        _ = cache.blocks(id: "m0", markdown: "text 0")
        #expect(cache.parseCount == 6)
    }
}
