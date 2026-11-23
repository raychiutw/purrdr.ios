import Foundation
import Testing

@testable import PurrdrFeatures

/// 加入 sheet 的最近照片分頁載入(#475):第一頁依可用高度算張數,捲到接近底部才載下一頁,不重複載入。
@MainActor
@Suite("最近照片分頁")
struct RecentPhotoPagerTests {
    /// 假相簿:`total` 張,記錄每次讀取的 (offset, limit)。
    @MainActor final class FakeAlbum {
        let total: Int
        private(set) var requests: [(offset: Int, limit: Int)] = []
        init(total: Int) { self.total = total }

        func fetch(offset: Int, limit: Int) async -> [RecentPhoto] {
            requests.append((offset, limit))
            guard offset < total else { return [] }
            return (offset..<min(total, offset + limit)).map { RecentPhoto(id: "p\($0)", thumbnail: Data()) }
        }
    }

    @Test("第一頁張數:填滿可用高度再多一列,每列 columns 張")
    func firstPageCount() {
        // 高 600、格子 90、間距 4:600 / 94 約 6.4 列 → 7 列 + 1 列緩衝 = 8 列。
        #expect(RecentPhotoPager.firstPageCount(availableHeight: 600, tileSide: 90, spacing: 4, columns: 4) == 32)
        // 很矮也至少 2 列。
        #expect(RecentPhotoPager.firstPageCount(availableHeight: 10, tileSide: 90, spacing: 4, columns: 4) == 8)
        // 還沒量到(0 或負)用最少 2 列。
        #expect(RecentPhotoPager.firstPageCount(availableHeight: 0, tileSide: 0, spacing: 4, columns: 4) == 8)
    }

    @Test("第一頁讀 firstPageCount 張,不讀整個相簿")
    func loadsOnlyFirstPage() async {
        let album = FakeAlbum(total: 500)
        let pager = RecentPhotoPager(columns: 4, fetch: album.fetch)

        await pager.loadFirstPage(count: 32)

        #expect(pager.photos.count == 32)
        #expect(album.requests.map(\.offset) == [0])
        #expect(album.requests.map(\.limit) == [32])
        #expect(pager.hasMore)
    }

    @Test("捲到接近底部才載下一頁;前面的格子出現不觸發")
    func loadsNextNearTheEnd() async {
        let album = FakeAlbum(total: 500)
        let pager = RecentPhotoPager(columns: 4, fetch: album.fetch)
        await pager.loadFirstPage(count: 32)

        await pager.tileAppeared(at: 5)
        #expect(album.requests.count == 1)

        await pager.tileAppeared(at: 31)
        #expect(album.requests.count == 2)
        #expect(album.requests[1].offset == 32)
        #expect(pager.photos.count == 32 + album.requests[1].limit)
        #expect(Set(pager.photos.map(\.id)).count == pager.photos.count, "沒有重複的照片")
    }

    @Test("同一個位置重複出現不重複載入;載入中不再發出第二個請求")
    func doesNotLoadTwice() async {
        let album = FakeAlbum(total: 500)
        let pager = RecentPhotoPager(columns: 4, fetch: album.fetch)
        await pager.loadFirstPage(count: 32)

        async let first: Void = pager.tileAppeared(at: 31)
        async let second: Void = pager.tileAppeared(at: 31)
        _ = await (first, second)
        await pager.tileAppeared(at: 31)

        #expect(album.requests.count == 2)
    }

    @Test("相簿讀完(回來的比要的少)就停止,之後不再讀")
    func stopsAtTheEnd() async {
        let album = FakeAlbum(total: 40)
        let pager = RecentPhotoPager(columns: 4, fetch: album.fetch)
        await pager.loadFirstPage(count: 32)
        await pager.tileAppeared(at: 31)

        #expect(pager.photos.count == 40)
        #expect(!pager.hasMore)
        await pager.tileAppeared(at: 39)
        #expect(album.requests.count == 2)
    }

    @Test("沒有權限或相簿是空的:沒有照片也不會一直重試")
    func emptyAlbum() async {
        let album = FakeAlbum(total: 0)
        let pager = RecentPhotoPager(columns: 4, fetch: album.fetch)
        await pager.loadFirstPage(count: 32)
        await pager.tileAppeared(at: 0)

        #expect(pager.photos.isEmpty)
        #expect(!pager.hasMore)
        #expect(album.requests.count == 1)
    }
}
