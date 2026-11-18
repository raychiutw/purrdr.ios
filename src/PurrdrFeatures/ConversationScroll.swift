import Foundation
import PurrdrAgentFeatures

/// 對話的捲動模式(行為規格 F5.12):**跟隨尾端**或**閱讀中**。
///
/// 只有使用者自己的捲動(手指按下到拖動或慣性結束)會改變模式;排版造成的位移只量測，不改模式(R-V01)。
/// 跟隨中，新內容與尺寸改變時捲到底;閱讀中不把讀者拉走(HIG:自動捲到底只在使用者位於底部時發生)。
public struct ConversationScroll: Equatable, Sendable {
    /// 距尾端在這個距離內算「在底部」。
    public static let threshold = 48.0

    private var following = true
    private var distanceFromBottom = 0.0
    /// 內容最近一次被重建的時間(#130):之後短時間內停在內容之外才捲到底。
    private var rebuiltAt: Date?
    /// 上次捲回內容時的內容高度(#185):高度沒變又被推回內容之外就不再捲，不與系統來回搶。
    private var returnedAtContentHeight: Double?

    /// 內容重建後這段時間內，停在內容之外就切回跟隨並捲到底(LazyVStack 重新估算高度要幾個畫面才定下來)。
    public static let rebuildSettleTime: TimeInterval = 1

    public init() {}

    /// 新內容、視窗或鍵盤尺寸改變、回到前景時要不要捲到底。
    public var autoScrollsOnNewContent: Bool { following }

    /// 「跳到最新」按鈕:閱讀中且距底超過門檻才出現。
    public var showsJumpToLatest: Bool { !following && distanceFromBottom > Self.threshold }

    /// 使用者自己捲動結束時呼叫。
    public mutating func userScrolled(distanceFromBottom: Double) {
        self.distanceFromBottom = distanceFromBottom
        rebuiltAt = nil
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
    /// 回音被對話紀錄確認(換成使用者訊息與回覆)或被拿掉不算重建。
    public func adjustment(from old: [String], to new: [String], visible: [String]) -> ConversationScrollAdjustment {
        guard !following, Self.isRebuild(from: old, to: new) else { return .none }
        let remaining = Set(new)
        if let anchor = visible.first(where: remaining.contains) { return .anchor(id: anchor) }
        return .bottom
    }

    /// 列表內容改變時呼叫(不論跟隨或閱讀中):記下重建的時間。
    public mutating func contentChanged(from old: [String], to new: [String], at now: Date) {
        if Self.isRebuild(from: old, to: new) { rebuiltAt = now }
    }

    /// 可見範圍停在內容之外時要不要切回跟隨並捲到底。跟隨尾端時一律要(開啟時 LazyVStack 的估算高度收斂，
    /// 可見範圍會落在內容之外);閱讀中只在內容剛被重建後(`rebuildSettleTime` 內、使用者之後沒有自己捲過),
    /// 一般排版變化(估算高度變小、reflow、鍵盤)不介入，閱讀中的讀者不被拉走。
    public func returnsToContent(_ metrics: ConversationScrollMetrics, at now: Date) -> Bool {
        guard metrics.isBeyondContent, metrics.contentHeight != returnedAtContentHeight else { return false }
        if following { return true }
        guard let rebuiltAt else { return false }
        return now.timeIntervalSince(rebuiltAt) <= Self.rebuildSettleTime
    }

    /// 跟隨中停在內容裡，可見範圍卻一列都沒顯示時要不要再捲到底(#191)。
    public func refillsVisibleRange(_ metrics: ConversationScrollMetrics, visibleRows: Int) -> Bool {
        false
    }

    /// `returnsToContent` 成立、畫面捲回內容時呼叫：切回跟隨，記下這次的內容高度。
    public mutating func returnedToContent(_ metrics: ConversationScrollMetrics) {
        jumpToLatest()
        returnedAtContentHeight = metrics.contentHeight
    }

    /// 重建：原有的列(不算回音)沒有原封不動、連續地留在新的列裡(後面接上、前面加上舊頁都不是)。
    static func isRebuild(from old: [String], to new: [String]) -> Bool {
        let old = old.filter { !$0.hasPrefix(ConversationEntry.echoIDPrefix) }
        guard let head = old.first else { return false }
        let new = new.filter { !$0.hasPrefix(ConversationEntry.echoIDPrefix) }
        guard let start = new.firstIndex(of: head), new.count - start >= old.count else { return true }
        return !new[start..<(start + old.count)].elementsEqual(old)
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
