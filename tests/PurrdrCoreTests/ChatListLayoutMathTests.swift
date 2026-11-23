import Foundation
import PurrdrCore
import Testing

/// 聊天列表 layout 的位置計算(#487)。
@Suite("聊天列表位置計算")
struct ChatListLayoutMathTests {
    @Test("閱讀中，可見範圍上方的列變高，位移補上差值")
    func rowAboveVisibleTopGrowsWhileReading() {
        let adjustment = ChatListLayoutMath.offsetAdjustment(
            rowMinY: 100, oldHeight: 60, newHeight: 160, visibleTop: 500,
            contentHeight: 2000, visibleHeight: 600, isFollowingLatest: false)
        #expect(adjustment == 100)
    }

    @Test("閱讀中，可見範圍內或下方的列變高，位移不變")
    func rowInsideOrBelowVisibleRangeGrowsWhileReading() {
        let inside = ChatListLayoutMath.offsetAdjustment(
            rowMinY: 520, oldHeight: 60, newHeight: 160, visibleTop: 500,
            contentHeight: 2000, visibleHeight: 600, isFollowingLatest: false)
        let straddlingTop = ChatListLayoutMath.offsetAdjustment(
            rowMinY: 480, oldHeight: 60, newHeight: 160, visibleTop: 500,
            contentHeight: 2000, visibleHeight: 600, isFollowingLatest: false)
        let below = ChatListLayoutMath.offsetAdjustment(
            rowMinY: 1500, oldHeight: 60, newHeight: 160, visibleTop: 500,
            contentHeight: 2000, visibleHeight: 600, isFollowingLatest: false)
        #expect(inside == 0)
        #expect(straddlingTop == 0)
        #expect(below == 0)
    }

    @Test("閱讀中，上方的列變矮，位移減去差值")
    func rowAboveVisibleTopShrinksWhileReading() {
        let adjustment = ChatListLayoutMath.offsetAdjustment(
            rowMinY: 100, oldHeight: 160, newHeight: 60, visibleTop: 500,
            contentHeight: 2000, visibleHeight: 600, isFollowingLatest: false)
        #expect(adjustment == -100)
    }

    @Test("跟隨最新，任何一列變高都補上可捲動範圍的增量，底部不動")
    func followingLatestKeepsBottomPinned() {
        let lastRowGrows = ChatListLayoutMath.offsetAdjustment(
            rowMinY: 1900, oldHeight: 60, newHeight: 160, visibleTop: 1400,
            contentHeight: 2000, visibleHeight: 600, isFollowingLatest: true)
        let earlierRowGrows = ChatListLayoutMath.offsetAdjustment(
            rowMinY: 1500, oldHeight: 60, newHeight: 160, visibleTop: 1400,
            contentHeight: 2000, visibleHeight: 600, isFollowingLatest: true)
        #expect(lastRowGrows == 100)
        #expect(earlierRowGrows == 100)
    }

    @Test("跟隨最新，內容還不到一屏時不補位移(由底部錨定推位置)")
    func followingLatestWithShortContentDoesNotAdjust() {
        let adjustment = ChatListLayoutMath.offsetAdjustment(
            rowMinY: 100, oldHeight: 60, newHeight: 160, visibleTop: 0,
            contentHeight: 300, visibleHeight: 600, isFollowingLatest: true)
        #expect(adjustment == 0)
    }

    @Test("跟隨最新，內容長到超過一屏時只補超出的部分")
    func followingLatestCrossingOneScreenAdjustsOnlyOverflow() {
        // 內容(含這次變高)原本 100，變高後 500，可見範圍 400 → 可捲動範圍從 0 變 100。
        let adjustment = ChatListLayoutMath.offsetAdjustment(
            rowMinY: 0, oldHeight: 60, newHeight: 460, visibleTop: 0,
            contentHeight: 100, visibleHeight: 400, isFollowingLatest: true)
        #expect(adjustment == 100)
    }

    @Test("高度沒變就不補")
    func unchangedHeightDoesNotAdjust() {
        let adjustment = ChatListLayoutMath.offsetAdjustment(
            rowMinY: 100, oldHeight: 60, newHeight: 60, visibleTop: 500,
            contentHeight: 2000, visibleHeight: 600, isFollowingLatest: true)
        #expect(adjustment == 0)
    }

    @Test("內容比可見範圍矮時往下推到底，夠高時不推")
    func bottomAnchorShift() {
        #expect(ChatListLayoutMath.bottomAnchorShift(contentHeight: 200, visibleHeight: 600) == 400)
        #expect(ChatListLayoutMath.bottomAnchorShift(contentHeight: 600, visibleHeight: 600) == 0)
        #expect(ChatListLayoutMath.bottomAnchorShift(contentHeight: 900, visibleHeight: 600) == 0)
    }

    @Test("捲到底的位移含底部 inset，內容不足一屏時停在頂端 inset")
    func bottomOffset() {
        #expect(ChatListLayoutMath.bottomOffset(contentHeight: 2000, boundsHeight: 800, insetTop: 100, insetBottom: 150) == 1350)
        #expect(ChatListLayoutMath.bottomOffset(contentHeight: 300, boundsHeight: 800, insetTop: 100, insetBottom: 150) == -100)
    }

    @Test("錨點列新位置減去它原本離可見頂端的距離，就是新的位移")
    func offsetKeepingRow() {
        #expect(ChatListLayoutMath.offsetKeepingRow(newRowMinY: 1240, distanceFromVisibleTop: 40, insetTop: 0) == 1200)
        #expect(ChatListLayoutMath.offsetKeepingRow(newRowMinY: 1240, distanceFromVisibleTop: 40, insetTop: 100) == 1100)
    }
}

/// 往上讀舊訊息的觸發規則(自舊捲動規則搬來,斷言不變)。
@Suite("往上讀舊訊息的觸發")
struct ChatListOlderPageTriggerTests {
    private func wants(content: Double, container: Double = 600, offset: Double = 0, dragged: Bool, pages: Int = 0) -> Bool {
        ChatListOlderPageTrigger.wantsOlderPage(
            distanceFromTop: offset, containerHeight: container, contentHeight: content,
            userHasDragged: dragged, autoLoadedPages: pages, autoLoadLimit: 25)
    }

    @Test("內容不夠填滿畫面:沒拖動過也往前讀")
    func underfilledContentLoadsOlderWithoutDragging() {
        #expect(wants(content: 300, dragged: false))
    }

    @Test("內容夠長、沒拖動過:不讀;拖動到離頂端一個畫面內才讀")
    func longContentWaitsForDragging() {
        #expect(!wants(content: 5_000, offset: 4_400, dragged: false))
        #expect(!wants(content: 5_000, offset: 4_400, dragged: true))
        #expect(wants(content: 5_000, offset: 500, dragged: true))
    }

    @Test("自動補讀有頁數上限;排版還沒量到(高度 0)不觸發")
    func autoLoadIsBoundedAndWaitsForLayout() {
        #expect(!wants(content: 300, dragged: false, pages: 25))
        #expect(wants(content: 300, dragged: true, pages: 25), "使用者拖動不受自動上限限制")
        #expect(!wants(content: 0, dragged: false))
        #expect(!wants(content: 300, container: 0, dragged: false))
    }
}
