import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 取檔記憶體快取(#591):所有主機共用總上限、記憶體警告清空、總量增量維護。
@Suite("主機取檔記憶體快取的共用上限")
struct HostFileCacheTests {
    static let root = "/Users/demo/ledger"
    static let scope = HostFileAccessScope(workingDirectories: [root], mentionedPaths: [])

    static func path(_ name: String) -> String { "\(root)/\(name)" }

    @Test("兩台主機的 loader 共用同一個上限:總量超過就丟最久沒用的")
    func totalLimitIsSharedAcrossLoaders() async {
        let cache = HostFileCache(limit: 250)
        let one = FakeHostFileFetcher(files: [Self.path("a.png"): Data(repeating: 1, count: 100)])
        let two = FakeHostFileFetcher(files: [Self.path("b.png"): Data(repeating: 2, count: 100), Self.path("c.png"): Data(repeating: 3, count: 100)])
        let first = HostFileLoader(fetcher: one, cache: cache)
        let second = HostFileLoader(fetcher: two, cache: cache)

        _ = await first.load(Self.path("a.png"), scope: Self.scope)
        _ = await second.load(Self.path("b.png"), scope: Self.scope)
        #expect(cache.totalBytes == 200)
        _ = await second.load(Self.path("c.png"), scope: Self.scope)

        #expect(cache.totalBytes <= 250, "每台各自 250 不算數,要共用")
        _ = await first.load(Self.path("a.png"), scope: Self.scope)
        #expect(await one.readCount == 2, "最舊的(第一台的 a)被丟掉,要重讀")
    }

    @Test("同一路徑換版本:舊版本的 bytes 從總量扣掉")
    func replacingAVersionKeepsTotalExact() async {
        let cache = HostFileCache(limit: 1_000)
        let fetcher = FakeHostFileFetcher(files: [Self.path("a.png"): Data(repeating: 1, count: 100)])
        let loader = HostFileLoader(fetcher: fetcher, cache: cache)
        _ = await loader.load(Self.path("a.png"), scope: Self.scope)
        await fetcher.put(Data(repeating: 2, count: 40), at: Self.path("a.png"))
        _ = await loader.load(Self.path("a.png"), scope: Self.scope)
        #expect(cache.totalBytes == 40)
    }

    @Test("記憶體警告:removeAll 清空,之後重讀")
    func removeAllEmptiesTheCache() async {
        let cache = HostFileCache(limit: 1_000)
        let fetcher = FakeHostFileFetcher(files: [Self.path("a.png"): Data(repeating: 1, count: 100)])
        let loader = HostFileLoader(fetcher: fetcher, cache: cache)
        _ = await loader.load(Self.path("a.png"), scope: Self.scope)
        #expect(cache.totalBytes == 100)

        cache.removeAll()
        #expect(cache.totalBytes == 0)
        _ = await loader.load(Self.path("a.png"), scope: Self.scope)
        #expect(await fetcher.readCount == 2)
        #expect(cache.totalBytes == 100)
    }
}
