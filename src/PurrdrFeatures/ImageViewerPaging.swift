import Foundation

/// 圖片檢視器(#426)的換頁規則:不依賴 SwiftUI,畫面只把滑動接到這組規則。索引一律夾在清單內。
struct ImageViewerPaging: Equatable {
    let count: Int
    private(set) var index: Int

    init(count: Int, startIndex: Int) {
        self.count = max(0, count)
        index = min(max(startIndex, 0), max(0, count - 1))
    }

    var canGoPrevious: Bool { index > 0 }
    var canGoNext: Bool { index < count - 1 }

    /// 頁數「1 / 2」;只有一張圖時不顯示。
    var pageLabel: String? { count > 1 ? "\(index + 1) / \(count)" : nil }

    mutating func goPrevious() { if canGoPrevious { index -= 1 } }
    mutating func goNext() { if canGoNext { index += 1 } }
    mutating func select(_ target: Int) { index = min(max(target, 0), max(0, count - 1)) }
}

/// 同一則訊息要放進檢視器的圖片(依訊息順序)與點的那張的索引。
/// 手機上有副本用副本;沒有副本的用主機路徑(經主機取檔讀完整圖);已知讀不到的(主機上找不到、被拒…)不進清單。
struct ImageViewerPlan: Equatable {
    enum Entry: Equatable {
        case local(URL)
        case host(String)
    }

    let entries: [Entry]
    let startIndex: Int

    /// - Parameters:
    ///   - images: 每張圖在手機上的副本(沒有是 `nil`)。
    ///   - hostPaths: 每張圖在主機上的路徑(依序對應 `images`,可能比 `images` 短)。
    ///   - tapped: 點的是第幾張(`images` 的索引)。
    ///   - isViewable: 主機路徑還有機會讀到圖。
    /// - Returns: 沒有任何可看的圖時 `nil`。
    init?(images: [URL?], hostPaths: [String?], tapped: Int, isViewable: (String) -> Bool) {
        var entries: [Entry] = []
        var start: Int?
        for (index, url) in images.enumerated() {
            let entry: Entry? =
                if let url { .local(url) } else if index < hostPaths.count, let path = hostPaths[index], isViewable(path) { .host(path) } else { nil }
            guard let entry else { continue }
            if index >= tapped, start == nil { start = entries.count }
            entries.append(entry)
        }
        guard !entries.isEmpty else { return nil }
        self.entries = entries
        // 點的那張一定在清單內;萬一不在(找不到的圖)落在它後面第一張,再不然最後一張。
        startIndex = start ?? entries.count - 1
    }
}
