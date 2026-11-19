import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 圖片縮圖的取檔(#225):先過 app 端存取規則，查狀態，自動載入只到 8 MiB;依版本分塊讀，快取鍵含版本。
@Suite("主機取檔的載入與快取")
struct HostFileLoaderTests {
    static let root = "/Users/demo/ledger"
    static let shot = "/Users/demo/ledger/docs/shot.png"
    static let scope = HostFileAccessScope(workingDirectories: [root], mentionedPaths: [shot])

    static func bytes(_ count: Int) -> Data { Data((0..<count).map { UInt8($0 % 256) }) }

    @Test("自動載入：查狀態後分塊讀完，拿到完整 bytes 與版本")
    func loadsInChunks() async {
        let image = Self.bytes(HostFileFetchLimits.chunkSize * 2 + 10)
        let fetcher = FakeHostFileFetcher(files: [Self.shot: image])
        let loader = HostFileLoader(fetcher: fetcher)

        guard case .loaded(let data, _) = await loader.load(Self.shot, scope: Self.scope) else { Issue.record("沒有載入"); return }
        #expect(data == image)
        #expect(await fetcher.requests == [
            .status(Self.shot), .read(Self.shot, offset: 0, length: HostFileFetchLimits.chunkSize),
            .read(Self.shot, offset: HostFileFetchLimits.chunkSize, length: HostFileFetchLimits.chunkSize),
            .read(Self.shot, offset: HostFileFetchLimits.chunkSize * 2, length: 10),
        ])
    }

    @Test("同一版本再載入只查狀態、用快取;Agent 覆寫後版本變了就重讀")
    func cacheKeyIncludesTheVersion() async {
        let fetcher = FakeHostFileFetcher(files: [Self.shot: Data("one".utf8)])
        let loader = HostFileLoader(fetcher: fetcher)
        _ = await loader.load(Self.shot, scope: Self.scope)

        guard case .loaded(let cached, _) = await loader.load(Self.shot, scope: Self.scope) else { Issue.record("沒有載入"); return }
        #expect(cached == Data("one".utf8))
        #expect(await fetcher.readCount == 1, "版本沒變不重讀")

        await fetcher.put(Data("two".utf8), at: Self.shot)
        guard case .loaded(let fresh, _) = await loader.load(Self.shot, scope: Self.scope) else { Issue.record("沒有載入"); return }
        #expect(fresh == Data("two".utf8))
        #expect(await fetcher.readCount == 2)
    }

    @Test("超過 8 MiB 不自動載入(只查狀態，回報大小);使用者點擊後載入")
    func automaticLimit() async {
        let big = Self.bytes(HostFileFetchLimits.automaticLoad + 1)
        let fetcher = FakeHostFileFetcher(files: [Self.shot: big])
        let loader = HostFileLoader(fetcher: fetcher)

        #expect(await loader.load(Self.shot, scope: Self.scope) == .overAutomaticLimit(size: big.count))
        #expect(await fetcher.readCount == 0)

        guard case .loaded(let data, _) = await loader.load(Self.shot, scope: Self.scope, userRequested: true) else { Issue.record("沒有載入"); return }
        #expect(data.count == big.count)
    }

    @Test("主機回報超過取檔上限：不讀，回報大小")
    func overTheMaximum() async {
        let fetcher = FakeHostFileFetcher(files: [Self.shot: Self.bytes(2_000)], maximumSize: 1_000)
        let loader = HostFileLoader(fetcher: fetcher)

        #expect(await loader.load(Self.shot, scope: Self.scope, userRequested: true) == .unavailable(.tooLarge(size: 2_000)))
        #expect(await fetcher.readCount == 0)
    }

    @Test("app 端規則不允許的路徑不送任何請求;主機端拒絕、缺檔、不支援各自回報")
    func refusalsAndFailures() async {
        let fetcher = FakeHostFileFetcher(files: ["/Users/demo/.ssh/id_ed25519": Data("k".utf8), "/Users/demo/ledger/link.png": Data("x".utf8)])
        await fetcher.deny("/Users/demo/ledger/link.png")
        let loader = HostFileLoader(fetcher: fetcher)
        let scope = HostFileAccessScope(workingDirectories: [Self.root], mentionedPaths: ["/Users/demo/.ssh/id_ed25519"])

        #expect(await loader.load("/Users/demo/.ssh/id_ed25519", scope: scope) == .unavailable(.denied))
        #expect(await loader.load("/Users/demo/notes/x.png", scope: scope) == .unavailable(.denied))
        #expect(await fetcher.requests.isEmpty, "app 端擋下的不送出")
        #expect(await loader.load("/Users/demo/ledger/link.png", scope: scope) == .unavailable(.denied))
        #expect(await loader.load("/Users/demo/ledger/gone.png", scope: scope) == .unavailable(.missing))
        #expect(await HostFileLoader(fetcher: FakeHostFileFetcher(isSupported: false)).load(Self.shot, scope: Self.scope) == .unavailable(.unsupported))
    }

    @Test("讀到一半檔案被覆寫：重新查狀態、讀新版本")
    func overwrittenWhileReading() async {
        let fetcher = FakeHostFileFetcher(files: [Self.shot: Data("old".utf8)])
        await fetcher.overwriteBeforeNextRead(Self.shot, with: Data("newer".utf8))
        let loader = HostFileLoader(fetcher: fetcher)

        guard case .loaded(let data, _) = await loader.load(Self.shot, scope: Self.scope) else { Issue.record("沒有載入"); return }
        #expect(data == Data("newer".utf8))
    }
}
