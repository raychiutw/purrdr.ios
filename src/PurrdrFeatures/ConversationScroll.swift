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
