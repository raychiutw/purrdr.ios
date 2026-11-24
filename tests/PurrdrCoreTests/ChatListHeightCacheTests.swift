import Foundation
import PurrdrCore
import Testing

/// 聊天列表量過的列高(列 id + 寬度 + 字級類別):量過就存,估計與自適應直接用,內容變了才作廢。
@Suite("聊天列表高度快取")
struct ChatListHeightCacheTests {
    static func cache() -> ChatListHeightCache {
        var cache = ChatListHeightCache(defaultHeight: 80)
        cache.configure(width: 358, category: "XXXL")
        return cache
    }

    @Test("量過的列:已知高度與估計都是量到的高度")
    func recordedRowIsKnown() {
        var cache = Self.cache()
        cache.record(id: "a", kind: "entry", height: 700)
        #expect(cache.knownHeight(for: "a") == 700)
        #expect(cache.estimate(for: "a", kind: "entry") == 700)
    }

    @Test("沒量過的列:沒有已知高度,估計用同種列的平均,沒有同種列時用預設值")
    func unknownRowEstimatesFromSameKind() {
        var cache = Self.cache()
        #expect(cache.knownHeight(for: "x") == nil)
        #expect(cache.estimate(for: "x", kind: "entry") == 80)
        cache.record(id: "a", kind: "entry", height: 600)
        cache.record(id: "b", kind: "entry", height: 800)
        cache.record(id: "w", kind: "working", height: 40)
        #expect(cache.estimate(for: "x", kind: "entry") == 700)
        #expect(cache.estimate(for: "y", kind: "working") == 40)
        #expect(cache.estimate(for: "z", kind: "notice") == 80)
    }

    @Test("同一列重複記錄以最後一次為準,平均也跟著換")
    func rerecordingReplacesTheOldHeight() {
        var cache = Self.cache()
        cache.record(id: "a", kind: "entry", height: 600)
        cache.record(id: "b", kind: "entry", height: 800)
        cache.record(id: "a", kind: "entry", height: 1000)
        #expect(cache.knownHeight(for: "a") == 1000)
        #expect(cache.estimate(for: "x", kind: "entry") == 900)
    }

    @Test("內容變了的列:不再是已知高度,但舊高度仍是下一次的估計")
    func invalidatedRowKeepsItsEstimate() {
        var cache = Self.cache()
        cache.record(id: "a", kind: "entry", height: 600)
        cache.invalidate(["a", "never-recorded"])
        #expect(cache.knownHeight(for: "a") == nil)
        #expect(cache.estimate(for: "a", kind: "entry") == 600)
        cache.record(id: "a", kind: "entry", height: 650)
        #expect(cache.knownHeight(for: "a") == 650)
    }

    @Test("列寬或字級類別改了:全部作廢;沒改就不動")
    func configureClearsOnlyWhenWidthOrCategoryChanges() {
        var cache = Self.cache()
        cache.record(id: "a", kind: "entry", height: 600)
        #expect(cache.configure(width: 358, category: "XXXL") == false)
        #expect(cache.knownHeight(for: "a") == 600)
        #expect(cache.configure(width: 390, category: "XXXL") == true)
        #expect(cache.knownHeight(for: "a") == nil)
        #expect(cache.estimate(for: "a", kind: "entry") == 80)
        cache.record(id: "a", kind: "entry", height: 500)
        #expect(cache.configure(width: 390, category: "L") == true)
        #expect(cache.count == 0)
    }

    @Test("只留還在列表裡的列,平均跟著更新")
    func pruneKeepsOnlyListedRows() {
        var cache = Self.cache()
        cache.record(id: "a", kind: "entry", height: 600)
        cache.record(id: "b", kind: "entry", height: 1000)
        cache.prune(keeping: ["b"])
        #expect(cache.count == 1)
        #expect(cache.knownHeight(for: "a") == nil)
        #expect(cache.estimate(for: "x", kind: "entry") == 1000)
        cache.prune(keeping: [])
        #expect(cache.estimate(for: "x", kind: "entry") == 80)
    }

    @Test("不合理的高度(0、負數、無限大)不記")
    func invalidHeightsAreIgnored() {
        var cache = Self.cache()
        cache.record(id: "a", kind: "entry", height: 0)
        cache.record(id: "b", kind: "entry", height: -5)
        cache.record(id: "c", kind: "entry", height: .infinity)
        #expect(cache.count == 0)
    }
}
