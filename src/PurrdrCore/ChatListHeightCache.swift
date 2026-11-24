import Foundation

/// 聊天列表量過的列高(ADR-0014 補充):列 id + 列寬 + 字級類別一致時，量過就存，下次當估計與自適應的已知高度用。
///
/// 為什麼需要:列表用估計高度先排、再逐列量實際高度補上;沒量過的列用同一個固定估計(60pt),
/// 長對話(XXXL 字級一列常上千 pt)在程式驅動的大幅跳動時，一串沒量過的列要逐一自適應並補償位移。
/// 有了已知高度，估計就等於實際，自適應不再讓 layout 失效。純邏輯，不依賴 UIKit。
public struct ChatListHeightCache: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var height: Double
        var kind: String
        /// 內容變了之後為 false:數值仍可當估計，但不能當「已量過」直接用。
        var isFresh: Bool
    }

    private struct KindStats: Equatable, Sendable {
        var sum = 0.0
        var count = 0
    }

    public private(set) var width: Double = 0
    public private(set) var category: String = ""
    public let defaultHeight: Double
    private var entries: [String: Entry] = [:]
    private var kinds: [String: KindStats] = [:]

    public init(defaultHeight: Double = 60) {
        self.defaultHeight = defaultHeight
    }

    public var count: Int { entries.count }

    /// 列寬或字級類別改了,全部作廢(高度只對同一個寬度與字級有意義)。回傳是否清掉了東西。
    @discardableResult
    public mutating func configure(width: Double, category: String) -> Bool {
        guard width != self.width || category != self.category else { return false }
        self.width = width
        self.category = category
        entries.removeAll()
        kinds.removeAll()
        return true
    }

    /// 記下量到的高度(同一列重複記以最後一次為準)。
    public mutating func record(id: String, kind: String, height: Double) {
        guard height > 0, height.isFinite else { return }
        if let old = entries[id] { subtract(old) }
        entries[id] = Entry(height: height, kind: kind, isFresh: true)
        var stats = kinds[kind] ?? KindStats()
        stats.sum += height
        stats.count += 1
        kinds[kind] = stats
    }

    /// 量過、內容沒變的高度;沒量過或已被 `invalidate` 時是 nil。
    public func knownHeight(for id: String) -> Double? {
        guard let entry = entries[id], entry.isFresh else { return nil }
        return entry.height
    }

    /// 排版用的估計高度:這一列量過(即使內容後來變了)就用它;否則同一種列的平均;都沒有就用預設值。
    public func estimate(for id: String, kind: String) -> Double {
        if let entry = entries[id] { return entry.height }
        if let stats = kinds[kind], stats.count > 0 { return stats.sum / Double(stats.count) }
        return defaultHeight
    }

    /// 這些列的內容變了:高度不能再直接用,但仍留著當下一次的估計。
    public mutating func invalidate(_ ids: some Sequence<String>) {
        for id in ids where entries[id] != nil { entries[id]?.isFresh = false }
    }

    /// 只留還在列表裡的列(列表裡的列才有意義,也讓大小有上限)。
    public mutating func prune(keeping ids: Set<String>) {
        for (id, entry) in entries where !ids.contains(id) {
            subtract(entry)
            entries[id] = nil
        }
    }

    private mutating func subtract(_ entry: Entry) {
        guard var stats = kinds[entry.kind] else { return }
        stats.sum -= entry.height
        stats.count -= 1
        kinds[entry.kind] = stats.count > 0 ? stats : nil
    }
}
