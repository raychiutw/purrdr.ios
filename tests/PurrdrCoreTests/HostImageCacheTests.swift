import Foundation
import PurrdrCore
import Testing

/// 主機圖片的縮圖與尺寸快取(#482):第二次顯示不重解碼、有尺寸立刻算得出列高、超過上限淘汰、版本變了重讀。
@Suite("主機圖片快取")
struct HostImageCacheTests {
    /// 解碼被呼叫的次數,代表「真的解碼了幾次」。
    final class DecodeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func hit() { lock.withLock { value += 1 } }
    }

    static let photoSize = ImagePixelSize(width: 400, height: 200)
    static func key(_ path: String = "/p/a.png", checksum: String = "v1", maxPixels: Int = 1024) -> HostImageKey {
        HostImageKey(path: path, version: HostFileVersion(checksum: checksum), maxPixels: maxPixels)
    }

    /// 縮圖用 Int 代表,成本就是它的值。
    static func cache(byteLimit: Int = 1_000) -> HostImageCache<Int> {
        HostImageCache<Int>(byteLimit: byteLimit, cost: { $0 })
    }

    @Test("同一張圖第二次顯示不重新解碼")
    func secondDisplayDoesNotDecodeAgain() async {
        let cache = Self.cache()
        let counter = DecodeCounter()

        let first = await cache.thumbnail(for: Self.key()) { counter.hit(); return (10, Self.photoSize) }
        let second = await cache.thumbnail(for: Self.key()) { counter.hit(); return (10, Self.photoSize) }

        #expect(first == 10)
        #expect(second == 10)
        #expect(counter.count == 1)
        #expect(cache.cachedThumbnail(for: Self.key()) == 10)
    }

    @Test("版本變了就重新解碼")
    func newVersionDecodesAgain() async {
        let cache = Self.cache()
        let counter = DecodeCounter()

        _ = await cache.thumbnail(for: Self.key(checksum: "v1")) { counter.hit(); return (10, Self.photoSize) }
        let changed = await cache.thumbnail(for: Self.key(checksum: "v2")) { counter.hit(); return (20, Self.photoSize) }

        #expect(changed == 20)
        #expect(counter.count == 2)
    }

    @Test("縮圖長邊不同是不同的快取項目")
    func differentMaxPixelsAreSeparateEntries() async {
        let cache = Self.cache()
        let counter = DecodeCounter()

        _ = await cache.thumbnail(for: Self.key(maxPixels: 1024)) { counter.hit(); return (10, Self.photoSize) }
        _ = await cache.thumbnail(for: Self.key(maxPixels: 192)) { counter.hit(); return (5, Self.photoSize) }

        #expect(counter.count == 2)
    }

    @Test("解碼失敗不快取,下次會再試")
    func failedDecodeIsNotCached() async {
        let cache = Self.cache()
        let counter = DecodeCounter()

        let failed = await cache.thumbnail(for: Self.key()) { counter.hit(); return nil }
        let retried = await cache.thumbnail(for: Self.key()) { counter.hit(); return (10, Self.photoSize) }

        #expect(failed == nil)
        #expect(retried == 10)
        #expect(counter.count == 2)
    }

    @Test("總成本超過上限時淘汰最久沒用的")
    func evictsLeastRecentlyUsedBeyondLimit() async {
        let cache = Self.cache(byteLimit: 100)
        _ = await cache.thumbnail(for: Self.key("/a")) { (40, Self.photoSize) }
        _ = await cache.thumbnail(for: Self.key("/b")) { (40, Self.photoSize) }
        // 用過 /a,/b 變成最久沒用的。
        #expect(cache.cachedThumbnail(for: Self.key("/a")) == 40)

        _ = await cache.thumbnail(for: Self.key("/c")) { (40, Self.photoSize) }

        #expect(cache.cachedThumbnail(for: Self.key("/b")) == nil)
        #expect(cache.cachedThumbnail(for: Self.key("/a")) == 40)
        #expect(cache.cachedThumbnail(for: Self.key("/c")) == 40)
        #expect(cache.totalCost == 80)
    }

    @Test("單一縮圖就超過上限時不放進快取")
    func oversizedThumbnailIsNotStored() async {
        let cache = Self.cache(byteLimit: 100)

        let shown = await cache.thumbnail(for: Self.key()) { (500, Self.photoSize) }

        #expect(shown == 500)
        #expect(cache.cachedThumbnail(for: Self.key()) == nil)
        #expect(cache.totalCost == 0)
    }

    @Test("預設上限是 48 MiB(規格約 48–64 MiB)")
    func defaultLimitIs48MiB() async {
        let cache = HostImageCache<Int>(cost: { $0 })
        let mib = 1024 * 1024

        _ = await cache.thumbnail(for: Self.key("/a")) { (47 * mib, Self.photoSize) }
        #expect(cache.cachedThumbnail(for: Self.key("/a")) != nil)
        // 再加 2 MiB 超過預設的 48 MiB,最久沒用的(/a)被淘汰。
        _ = await cache.thumbnail(for: Self.key("/b")) { (2 * mib, Self.photoSize) }
        #expect(cache.cachedThumbnail(for: Self.key("/a")) == nil)
        #expect(cache.cachedThumbnail(for: Self.key("/b")) != nil)
        #expect(cache.totalCost == 2 * mib)
    }

    @Test("解碼後記下尺寸,同路徑同版本立刻查得到")
    func decodedSizeIsKnownImmediately() async {
        let cache = Self.cache()
        let version = HostFileVersion(checksum: "v1")
        #expect(cache.size(forPath: "/p/a.png", version: version) == nil)

        _ = await cache.thumbnail(for: Self.key()) { (10, Self.photoSize) }

        #expect(cache.size(forPath: "/p/a.png", version: version) == Self.photoSize)
    }

    @Test("對話紀錄帶的尺寸在還沒載入(不知道版本)時就能用")
    func transcriptSizeServesBeforeLoad() {
        let cache = Self.cache()

        cache.recordTranscriptSize(Self.photoSize, forPath: "/p/a.png")

        #expect(cache.size(forPath: "/p/a.png") == Self.photoSize)
    }

    @Test("解碼後記下的尺寸優先於對話紀錄帶的")
    func decodedSizeWinsOverTranscriptSize() async {
        let cache = Self.cache()
        cache.recordTranscriptSize(ImagePixelSize(width: 10, height: 10), forPath: "/p/a.png")

        _ = await cache.thumbnail(for: Self.key()) { (10, Self.photoSize) }

        #expect(cache.size(forPath: "/p/a.png", version: HostFileVersion(checksum: "v1")) == Self.photoSize)
    }

    @Test("有尺寸時立刻算出列高:長邊 220、依比例")
    func knownSizeGivesRowHeightImmediately() {
        let fitted = Self.photoSize.fitted(longEdge: 220)

        #expect(fitted?.width == 220)
        #expect(fitted?.height == 110)
        #expect(ImagePixelSize(width: 100, height: 300).fitted(longEdge: 220)?.width == 73)
        #expect(ImagePixelSize(width: 0, height: 300).fitted(longEdge: 220) == nil)
    }
}
