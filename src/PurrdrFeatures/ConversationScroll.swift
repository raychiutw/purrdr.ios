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
    /// 上次捲回內容時的排版(#185):排版沒變又被推回內容之外，只再以位移捲一次，不與系統來回搶。
    private var returnedAtLayout: ConversationScrollMetrics.Layout?
    /// 同一個排版第二次捲回(改以底部位移)的排版(#251):再被推回內容之外就真的不再捲。
    private var offsetReturnedAtLayout: ConversationScrollMetrics.Layout?
    /// 以位移捲回(或之後再以位移捲)時的排版;`nil` 是還沒以位移捲過(#251)。
    private var offsetFollowedLayout: ConversationScrollMetrics.Layout?
    /// 以位移捲回後再以位移捲的次數。
    private var offsetFollows = 0
    /// 一列都沒顯示時已經再捲的次數(#191)。
    private var refills = 0
    /// 沒有新內容、使用者也沒捲、可見範圍高度也沒變時已經連續捲回內容的次數(#251)。
    private var returns = 0
    /// 上面那些捲回時的可見範圍高度：變了(鍵盤、輸入列、旋轉)就重新計算。
    private var returnsContainerHeight: Double?

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
        refills = 0
        returns = 0
        offsetFollowedLayout = nil
        following = distanceFromBottom <= Self.threshold
    }

    /// 排版造成的位移:只更新量測。
    public mutating func layoutChanged(distanceFromBottom: Double) {
        self.distanceFromBottom = distanceFromBottom
    }

    /// 這次捲回要不要直接捲到底部位移(`bottomScrollPositionY`)而不是最後一列(#251)。
    public func returnsByOffset(_ metrics: ConversationScrollMetrics) -> Bool { metrics.layout == returnedAtLayout }

    /// 以位移捲回後(`returnsByOffset`),ScrollPosition 停在那個位移、不再跟著底部;那裡的列排出實際高度、內容變高，
    /// 畫面就停在對話中間(AX5 開啟長對話,#251)。跟隨中、排版又變了(內容變高、停止列或鍵盤讓可見範圍變小)、不在底部時，以新的底部位移再捲。
    /// 捲動途中同一個排版的位置不算;次數有上限，使用者自己捲過或下一次以位移捲回時重新計算。
    public func followsByOffset(_ metrics: ConversationScrollMetrics) -> Bool {
        guard following, let layout = offsetFollowedLayout, offsetFollows < Self.maximumOffsetFollows else { return false }
        // 以位移捲就是要貼齊底部：差 1pt 以上就再捲(「在底部」的門檻 48pt 會讓最後一列有一截留在輸入卡片底下)。
        return metrics.layout != layout && abs(metrics.distanceFromBottom) > 1
    }

    /// `followsByOffset` 成立、畫面以新的底部位移再捲時呼叫。
    public mutating func followedByOffset(_ metrics: ConversationScrollMetrics) {
        offsetFollowedLayout = metrics.layout
        offsetFollows += 1
    }

    /// 以位移捲回後、內容高度又變時再以位移捲的次數上限(#251)。
    public static let maximumOffsetFollows = 5

    /// 跟隨中畫面捲去顯示新出現、但不是對話項目的內容(slash 面板、需要你、工作中指示)時呼叫(#251)。
    public mutating func followedNewContent() {
        returns = 0
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
        if old != new { returns = 0 }
    }

    /// 可見範圍停在內容之外時要不要切回跟隨並捲到底。跟隨尾端時一律要(開啟時 LazyVStack 的估算高度收斂，
    /// 可見範圍會落在內容之外);閱讀中只在內容剛被重建後(`rebuildSettleTime` 內、使用者之後沒有自己捲過),
    /// 一般排版變化(估算高度變小、reflow、鍵盤)不介入，閱讀中的讀者不被拉走。
    public func returnsToContent(_ metrics: ConversationScrollMetrics, at now: Date, byOffsetAllowed: Bool = true) -> Bool {
        // 同一個排版最多兩次：第一次捲到最後一列，又被推回內容之外(捲到最後一列多捲一個底部 inset)再以位移捲一次(#251)。
        // 不能以位移捲時(面板卡片開著)只受連續次數上限約束，每次都捲到最後一列。
        guard metrics.isBeyondContent, metrics.containerHeight >= Self.minimumRowHeight,
              !byOffsetAllowed || metrics.layout != offsetReturnedAtLayout,
              canReturnAgain(metrics) else {
            return false
        }
        if following { return true }
        guard let rebuiltAt else { return false }
        return now.timeIntervalSince(rebuiltAt) <= Self.rebuildSettleTime
    }

    /// 跟隨中，可見範圍至少一列高卻一列都沒顯示時要不要再捲到底(#191)。
    /// 同一個排版只捲一次，次數也有上限，不與系統來回搶(#185)。
    public func refillsVisibleRange(_ metrics: ConversationScrollMetrics, visibleRows: Int) -> Bool {
        following && visibleRows == 0 && refills < Self.maximumRefills && canReturnAgain(metrics)
            && metrics.containerHeight >= Self.minimumRowHeight && metrics.contentHeight > metrics.containerHeight
            && metrics.layout != returnedAtLayout
    }

    /// 可見範圍比這還矮就畫不出任何列(觸控目標的最小高度)。
    public static let minimumRowHeight = 44.0

    /// 再捲一次的次數上限(有列顯示過、使用者自己捲過就重新計算)。
    public static let maximumRefills = 3

    /// 沒有新內容、使用者也沒捲、可見範圍高度也沒變時，連續捲回內容的次數上限(#251):LazyVStack 的估算高度
    /// 在兩個值之間來回跳、列長出來又消失時，只記上一次的排版擋不住，主執行緒會一直捲。
    public static let maximumReturns = 3

    private func canReturnAgain(_ metrics: ConversationScrollMetrics) -> Bool {
        returns < Self.maximumReturns || metrics.containerHeight != returnsContainerHeight
    }

    /// 畫面上看得到的列數改變時呼叫。
    public mutating func visibleRowsChanged(count: Int) {
        if count > 0 { refills = 0 }
    }

    /// `returnsToContent` 或 `refillsVisibleRange` 成立、畫面捲回內容時呼叫：切回跟隨，記下這次的排版。
    public mutating func returnedToContent(_ metrics: ConversationScrollMetrics, byOffsetAllowed: Bool = true) {
        jumpToLatest()
        if byOffsetAllowed, metrics.layout == returnedAtLayout {
            offsetReturnedAtLayout = metrics.layout
            offsetFollowedLayout = metrics.layout
            offsetFollows = 0
        }
        returnedAtLayout = metrics.layout
        refills += 1
        if metrics.containerHeight != returnsContainerHeight {
            returns = 0
            returnsContainerHeight = metrics.containerHeight
        }
        returns += 1
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

    /// 不含捲動位置的排版：內容高、可見範圍高與上下 inset。
    public struct Layout: Equatable, Sendable {
        var contentHeight: Double
        var containerHeight: Double
        var topInset: Double
        var bottomInset: Double
    }

    public var layout: Layout {
        Layout(contentHeight: contentHeight, containerHeight: containerHeight, topInset: topInset, bottomInset: bottomInset)
    }

    /// 捲到底時 `ScrollPosition.scrollTo(y:)` 要給的值：從內容頂端量起、不含頂部 inset(實測 `scrollTo(y:)` 之後
    /// contentOffset 少一個頂部 inset,#251)。內容比畫面矮時是 0。
    public var bottomScrollPositionY: Double {
        max(contentHeight - containerHeight, 0)
    }

    /// 可見範圍頂緣到內容頂緣的距離。
    public var distanceFromTop: Double {
        contentOffsetY + topInset
    }
}
