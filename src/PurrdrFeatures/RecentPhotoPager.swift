import Foundation
import Observation

/// 加入 sheet「最近的照片」的分頁載入(#475):第一頁依可用高度算張數,捲到接近底部才載下一頁,不一次讀完整個相簿。
@MainActor
@Observable
final class RecentPhotoPager {
    typealias Fetch = @MainActor (_ offset: Int, _ limit: Int) async -> [RecentPhoto]

    private(set) var photos: [RecentPhoto] = []
    /// 相簿還有沒讀的照片(回來的比要的少就是讀完了)。
    private(set) var hasMore = true

    private let columns: Int
    private let fetch: Fetch
    private var isLoading = false

    init(columns: Int, fetch: @escaping Fetch) {
        self.columns = columns
        self.fetch = fetch
    }

    /// 第一頁的張數:填滿可用高度再多一列緩衝,至少 2 列。
    static func firstPageCount(availableHeight: CGFloat, tileSide: CGFloat, spacing: CGFloat, columns: Int) -> Int {
        let rowHeight = tileSide + spacing
        let visibleRows = rowHeight > 0 && availableHeight > 0 ? Int((availableHeight / rowHeight).rounded(.up)) : 0
        return max(2, visibleRows + 1) * columns
    }

    /// 之後每一頁的張數(6 列)。
    private var nextPageCount: Int { columns * 6 }

    func loadFirstPage(count: Int) async {
        guard photos.isEmpty, !isLoading else { return }
        await load(offset: 0, limit: count)
    }

    /// 第 `index` 格出現:接近目前載入的尾端(最後兩列)就載下一頁。
    func tileAppeared(at index: Int) async {
        guard hasMore, !isLoading, !photos.isEmpty, index >= photos.count - columns * 2 else { return }
        await load(offset: photos.count, limit: nextPageCount)
    }

    private func load(offset: Int, limit: Int) async {
        isLoading = true
        defer { isLoading = false }
        let page = await fetch(offset, limit)
        let known = Set(photos.map(\.id))
        photos.append(contentsOf: page.filter { !known.contains($0.id) })
        if page.count < limit { hasMore = false }
    }
}
