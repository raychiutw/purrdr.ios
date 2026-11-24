import Foundation

/// 聊天列表自訂 layout 的位置計算(ADR-0014):插入、往上補舊訊息與列高改變時，同一次排版內補好捲動位置。純數學，不依賴 UIKit。
public enum ChatListLayoutMath {
    /// 某一列的高度從 `oldHeight` 變成 `newHeight` 時，同一次排版內要補的 contentOffset 位移。
    ///
    /// 跟隨最新：底部錨定，補上可捲動範圍的增量。其餘：只有完全在可見範圍上方的列改變高度才補整個差值，可見內容不動。
    /// `contentHeight` 是這次變動前的內容高度。
    public static func offsetAdjustment(
        rowMinY: Double, oldHeight: Double, newHeight: Double, visibleTop: Double,
        contentHeight: Double, visibleHeight: Double, isFollowingLatest: Bool
    ) -> Double {
        let heightChange = newHeight - oldHeight
        guard heightChange != 0 else { return 0 }
        if isFollowingLatest {
            let scrollableBefore = max(0, contentHeight - visibleHeight)
            let scrollableAfter = max(0, contentHeight + heightChange - visibleHeight)
            return scrollableAfter - scrollableBefore
        }
        return rowMinY + oldHeight <= visibleTop ? heightChange : 0
    }

    /// 內容比可見範圍矮時，整份內容往下推多少，讓內容貼著底部(短對話貼著輸入列)。
    public static func bottomAnchorShift(contentHeight: Double, visibleHeight: Double) -> Double {
        max(0, visibleHeight - contentHeight)
    }

    /// 捲到最底時的 contentOffset.y(含上下 inset;內容不足一屏時停在頂端 inset)。
    public static func bottomOffset(contentHeight: Double, boundsHeight: Double, insetTop: Double, insetBottom: Double) -> Double {
        max(-insetTop, contentHeight + insetBottom - boundsHeight)
    }

    /// 捲到某一列時的 contentOffset.y:該列底緣停在可見底緣,不超過內容底端,內容不足一屏時停在頂端 inset。
    public static func offsetShowingRowBottom(
        rowMaxY: Double, boundsHeight: Double, insetTop: Double, insetBottom: Double, contentHeight: Double
    ) -> Double {
        let limit = bottomOffset(contentHeight: contentHeight, boundsHeight: boundsHeight, insetTop: insetTop, insetBottom: insetBottom)
        return min(limit, max(-insetTop, rowMaxY + insetBottom - boundsHeight))
    }

    /// 往上補舊訊息、內容變動後，讓錨點列維持在畫面上原本的位置時的 contentOffset.y。
    public static func offsetKeepingRow(newRowMinY: Double, distanceFromVisibleTop: Double, insetTop: Double) -> Double {
        newRowMinY - distanceFromVisibleTop - insetTop
    }
}

/// 往上讀舊訊息的觸發規則(#473 沿用;#487 從舊捲動規則搬到核心)。
public enum ChatListOlderPageTrigger {
    /// 距頂端 ≤ 1 個畫面高時,使用者拖動過就讀;沒拖動過時只有內容還不夠填滿(量得到排版之後)才自動讀,而且最多 `autoLoadLimit` 頁
    /// (整份都是工具步驟時摺起來的高度很短,不能一路讀到檔案開頭)。
    public static func wantsOlderPage(
        distanceFromTop: Double, containerHeight: Double, contentHeight: Double,
        userHasDragged: Bool, autoLoadedPages: Int, autoLoadLimit: Int
    ) -> Bool {
        guard distanceFromTop <= containerHeight else { return false }
        if userHasDragged { return true }
        return contentHeight > 0 && containerHeight > 0 && autoLoadedPages < autoLoadLimit
    }
}

/// 列表延伸到玻璃導覽列、橫幅與輸入列底下時,交給 `contentInset` 的上下留白(DESIGN.md:內容從玻璃底下捲過去)。
public enum ChatListInsetMath {
    /// 列表框與「避開玻璃控制後的安全區域框」(同一個座標系)的差;安全區域框超出列表時不出現負值。
    public static func insets(listMinY: Double, listMaxY: Double, safeMinY: Double, safeMaxY: Double) -> (top: Double, bottom: Double) {
        (max(0, safeMinY - listMinY), max(0, listMaxY - safeMaxY))
    }
}
