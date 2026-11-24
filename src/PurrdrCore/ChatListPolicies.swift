import Foundation

/// 聊天列表「打開時捲到底」的時機。
public enum ChatListInitialPosition {
    /// 第一次有內容的套用才需要定位到底部;空內容的套用(快取還沒到)不能把這個時機用掉。
    public static func needsScroll(hadContent: Bool, hasContent: Bool) -> Bool {
        !hadContent && hasContent
    }
}

/// 套用新內容的時機:拖曳、鍵盤動畫、選單開著、畫面正在離開時先留著,安全了再套用(spec #480)。
public enum ChatListApplyGate {
    /// 第一次套用一律立刻做(此時畫面上還沒有東西可以被打斷)。
    /// `isLeaving`:列表正在離開畫面(返回列表的轉場、推入子頁)。畫面已經在移走,套用只會把版面計算塞進轉場裡
    /// (轉場期間的卡頓與動畫尾段凍結),所以留到回來(`viewWillAppear`)再套用;離開後這個畫面就會被釋放,內容不再需要。
    public static func shouldDefer(
        isFirstApply: Bool, isUserDriven: Bool, isKeyboardAnimating: Bool, isMenuOpen: Bool, isLeaving: Bool = false
    ) -> Bool {
        guard !isFirstApply else { return false }
        return isUserDriven || isKeyboardAnimating || isMenuOpen || isLeaving
    }
}

/// 內容套用的批次(spec #480):約每 `interval` 才套用一次;第一次與間隔夠久時立刻套用。
public enum ChatListApplyBatch {
    /// 距離可以套用還要等多久(0 = 現在就套用)。
    public static func delay(now: TimeInterval, lastApplyAt: TimeInterval?, interval: TimeInterval) -> TimeInterval {
        guard let lastApplyAt else { return 0 }
        return max(0, interval - (now - lastApplyAt))
    }
}
