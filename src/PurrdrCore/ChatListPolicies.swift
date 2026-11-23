import Foundation

/// 聊天列表「打開時捲到底」的時機。
public enum ChatListInitialPosition {
    /// 第一次有內容的套用才需要定位到底部;空內容的套用(快取還沒到)不能把這個時機用掉。
    public static func needsScroll(hadContent: Bool, hasContent: Bool) -> Bool {
        !hadContent && hasContent
    }
}

/// 套用新內容的時機:拖曳、鍵盤動畫、選單開著時先留著,安全了再套用(spec #480)。
public enum ChatListApplyGate {
    /// 第一次套用一律立刻做(此時畫面上還沒有東西可以被打斷)。
    public static func shouldDefer(isFirstApply: Bool, isUserDriven: Bool, isKeyboardAnimating: Bool, isMenuOpen: Bool) -> Bool {
        guard !isFirstApply else { return false }
        return isUserDriven || isKeyboardAnimating || isMenuOpen
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
