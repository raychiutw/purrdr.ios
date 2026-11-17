/// 對話的捲動模式(行為規格 F5.12):**跟隨尾端**或**閱讀中**。
///
/// 只有使用者自己的捲動(手指按下到拖動或慣性結束)會改變模式;排版造成的位移只量測，不改模式(R-V01)。
/// 跟隨中，新內容與尺寸改變時捲到底;閱讀中不把讀者拉走(HIG:自動捲到底只在使用者位於底部時發生)。
public struct ConversationScroll: Equatable, Sendable {
    /// 距尾端在這個距離內算「在底部」。
    public static let threshold = 48.0

    private var following = true
    private var distanceFromBottom = 0.0

    public init() {}

    /// 新內容、視窗或鍵盤尺寸改變、回到前景時要不要捲到底。
    public var autoScrollsOnNewContent: Bool { following }

    /// 「跳到最新」按鈕:閱讀中且距底超過門檻才出現。
    public var showsJumpToLatest: Bool { !following && distanceFromBottom > Self.threshold }

    /// 使用者自己捲動結束時呼叫。
    public mutating func userScrolled(distanceFromBottom: Double) {
        self.distanceFromBottom = distanceFromBottom
        following = distanceFromBottom <= Self.threshold
    }

    /// 排版造成的位移:只更新量測。
    public mutating func layoutChanged(distanceFromBottom: Double) {
        self.distanceFromBottom = distanceFromBottom
    }

    /// 開啟、點「跳到最新」、重新載入:變跟隨並捲到底。
    public mutating func jumpToLatest() {
        following = true
        distanceFromBottom = 0
    }
}

/// 內容被重建或大量增加時的捲動調整(#130)。
public enum ConversationScrollAdjustment: Equatable, Sendable {
    case none
    /// 把這則訊息放回可見範圍頂端。
    case anchor(id: String)
    /// 切回跟隨並捲到底。
    case bottom
}

extension ConversationScroll {
    /// 內容從 `old` 變成 `new`(列表項目的 id)時的調整。`visible` 是變更前畫面上看得到的項目(由上而下)。
    ///
    /// 跟隨中交給「捲到底」。閱讀中：只在後面接上或前面加上舊頁時不動(原本的內容原封不動，位置不跳);
    /// 內容被重建時，把畫面上第一個仍存在的訊息放回頂端;都不在了就捲到底，不停在內容之外。
    public func adjustment(from old: [String], to new: [String], visible: [String]) -> ConversationScrollAdjustment {
        guard !following, !old.isEmpty, !Self.contains(new, run: old) else { return .none }
        let remaining = Set(new)
        if let anchor = visible.first(where: remaining.contains) { return .anchor(id: anchor) }
        return .bottom
    }

    /// `run` 原封不動、連續地出現在 `items` 裡。
    private static func contains(_ items: [String], run: [String]) -> Bool {
        guard let start = items.firstIndex(of: run[0]), items.count - start >= run.count else { return false }
        return items[start..<(start + run.count)].elementsEqual(run)
    }
}

/// 對話捲動的量測值，取自 SwiftUI `ScrollGeometry`。
///
/// `containerHeight` 是 `containerSize.height`,**已扣掉** content insets(導覽列、輸入列);捲到底時
/// `contentOffsetY` = 內容高 + 底部 inset − 整個捲動視圖高 = 內容高 − `containerHeight` − 頂部 inset。
public struct ConversationScrollMetrics: Equatable, Sendable {
    public var contentHeight: Double
    public var containerHeight: Double
    public var contentOffsetY: Double
    public var topInset: Double
    public var bottomInset: Double

    public init(contentHeight: Double, containerHeight: Double, contentOffsetY: Double, topInset: Double, bottomInset: Double) {
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.contentOffsetY = contentOffsetY
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    /// 可見範圍底緣到內容底緣的距離;內容短到不用捲時是負的。
    public var distanceFromBottom: Double {
        contentHeight - containerHeight - topInset - contentOffsetY
    }

    /// 可見範圍停在內容之外：內容比畫面高，可見範圍底緣卻超過內容底緣一個門檻以上(例如內容突然縮短)。
    public var isBeyondContent: Bool {
        contentHeight > containerHeight && distanceFromBottom < -ConversationScroll.threshold
    }

    /// 可見範圍頂緣到內容頂緣的距離。
    public var distanceFromTop: Double {
        contentOffsetY + topInset
    }
}
