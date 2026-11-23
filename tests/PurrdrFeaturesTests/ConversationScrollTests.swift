import Foundation
import PurrdrFeatures
import Testing

/// 捲動規則(行為規格 F5.12、R-V01、HIG 20.5「自動捲到底只在使用者位於底部時發生」)。
@Suite("對話捲動")
struct ConversationScrollTests {
    @Test("開啟時跟隨尾端：新內容自動捲到底")
    func followsTailInitially() {
        let scroll = ConversationScroll()
        #expect(scroll.autoScrollsOnNewContent)
    }

    @Test("使用者往上捲(距底 > 48pt)後變閱讀中：新內容不把他拉走")
    func userScrollingUpStopsFollowing() {
        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: 49)
        #expect(scroll.autoScrollsOnNewContent == false)
    }

    @Test("使用者捲回距底 48pt 內就恢復跟隨")
    func userScrollingBackResumesFollowing() {
        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: 400)
        scroll.userScrolled(distanceFromBottom: 48)
        #expect(scroll.autoScrollsOnNewContent)
    }

    /// R-V01:排版造成的捲動事件只量測、不改模式(否則沒動的讀者會停在離底一截的地方)。
    @Test("排版造成的位移不改變模式")
    func layoutShiftsDoNotChangeMode() {
        var scroll = ConversationScroll()
        scroll.layoutChanged(distanceFromBottom: 600)
        #expect(scroll.autoScrollsOnNewContent)

        scroll.userScrolled(distanceFromBottom: 600)
        scroll.layoutChanged(distanceFromBottom: 10)
        #expect(scroll.autoScrollsOnNewContent == false)
    }

    @Test("跳到最新：閱讀中且距底 > 48pt 才出現;點了變跟隨")
    func jumpToLatestButton() {
        var scroll = ConversationScroll()
        #expect(scroll.showsJumpToLatest == false)
        scroll.userScrolled(distanceFromBottom: 300)
        #expect(scroll.showsJumpToLatest)

        scroll.jumpToLatest()
        scroll.layoutChanged(distanceFromBottom: 0)
        #expect(scroll.showsJumpToLatest == false)
        #expect(scroll.autoScrollsOnNewContent)
    }

    /// #476 重現:跟隨尾端時內容被撐長、自動捲到底沒有落地(估算高度、往前補讀、鍵盤開合後),實際已離底很遠;
    /// 舊規則以「是否跟隨」為條件,按鈕不出現,使用者看不到回到最新的入口。顯示只看離底距離。
    @Test("跟隨尾端但實際離底很遠:仍顯示跳到最新(#476)")
    func showsWhenFarFromBottomEvenWhileFollowing() {
        var scroll = ConversationScroll()
        #expect(scroll.autoScrollsOnNewContent)
        scroll.layoutChanged(distanceFromBottom: 600)
        #expect(scroll.showsJumpToLatest)
        scroll.layoutChanged(distanceFromBottom: 48)
        #expect(scroll.showsJumpToLatest == false)
    }

    @Test("點跳到最新後:捲動沒落地(量到的距離仍遠)按鈕仍在,不因旗標而消失(#476)")
    func tapKeepsButtonUntilMeasuredAtBottom() {
        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: 900)
        scroll.jumpToLatestByTap()
        #expect(scroll.showsJumpToLatest, "還沒量到抵達底部,不能先假設已到")
        scroll.layoutChanged(distanceFromBottom: 900)
        #expect(scroll.showsJumpToLatest)
        scroll.layoutChanged(distanceFromBottom: 0)
        #expect(scroll.showsJumpToLatest == false)
        #expect(scroll.autoScrollsOnNewContent)
    }

    @Test("點跳到最新時畫面還在減速(#401):減速中量到的位移不把模式改回閱讀中，按鈕不再冒出來")
    func jumpWhileDeceleratingIsNotOverriddenByInertia() {
        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: 900)
        scroll.jumpToLatestByTap()
        // 慣性還在捲、按鈕剛點下:捲動途中的量測仍算「使用者捲動」,不能把跟隨改回去。
        scroll.userScrolled(distanceFromBottom: 700)
        #expect(scroll.autoScrollsOnNewContent)
        // 顯示只看量到的距離(#476):還沒抵達底部時按鈕仍在,抵達後才收起。
        scroll.userScrolled(distanceFromBottom: 0)
        #expect(scroll.showsJumpToLatest == false)
    }

    @Test("點跳到最新之後使用者再次按下拖動才算新的閱讀(#401)")
    func newDragAfterJumpReturnsToReading() {
        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: 900)
        scroll.jumpToLatestByTap()
        scroll.userScrolled(distanceFromBottom: 700)
        scroll.userBeganDragging()
        scroll.userScrolled(distanceFromBottom: 500)
        #expect(scroll.autoScrollsOnNewContent == false)
        #expect(scroll.showsJumpToLatest)
    }

    // iPhone 17 模擬器實測的 ScrollGeometry(Demo「需要你」對話，#93):
    // 內容高 844、containerSize 高 672(已扣掉導覽列 116 與輸入列 86 的 inset)、捲動視圖整體 874。
    // 捲到底時 contentOffset.y = 56,在頂端時 = −116。
    static func measured(offsetY: Double, contentHeight: Double = 844) -> ConversationScrollMetrics {
        ConversationScrollMetrics(
            contentHeight: contentHeight, containerHeight: 672, contentOffsetY: offsetY, topInset: 116, bottomInset: 86
        )
    }

    @Test("在底部：距底 0,往上捲回底部後按鈕隱藏並恢復跟隨")
    func atBottomHidesJumpToLatest() {
        let bottom = Self.measured(offsetY: 56)
        #expect(bottom.distanceFromBottom == 0)

        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: Self.measured(offsetY: -116).distanceFromBottom)
        #expect(scroll.showsJumpToLatest)
        scroll.userScrolled(distanceFromBottom: bottom.distanceFromBottom)
        #expect(scroll.showsJumpToLatest == false)
        #expect(scroll.autoScrollsOnNewContent)
    }

    @Test("不在底部：在頂端距底 172、距頂 0,按鈕顯示")
    func awayFromBottomShowsJumpToLatest() {
        let top = Self.measured(offsetY: -116)
        #expect(top.distanceFromBottom == 172)
        #expect(top.distanceFromTop == 0)

        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: top.distanceFromBottom)
        #expect(scroll.showsJumpToLatest)
    }

    @Test("對話短到不用捲：距底不為正，按鈕不顯示")
    func shortConversationHidesJumpToLatest() {
        let short = Self.measured(offsetY: -116, contentHeight: 500)
        #expect(short.distanceFromBottom <= 0)

        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: short.distanceFromBottom)
        #expect(scroll.showsJumpToLatest == false)
    }

    @Test("新訊息跟隨：新內容撐開距離只是暫時(畫面延遲顯示按鈕避免閃現，#476),捲到底量到 0 就收起")
    func newContentWhileFollowingHidesJumpToLatest() {
        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: Self.measured(offsetY: 56).distanceFromBottom)
        scroll.layoutChanged(distanceFromBottom: Self.measured(offsetY: 56, contentHeight: 1244).distanceFromBottom)
        #expect(scroll.autoScrollsOnNewContent)
        scroll.layoutChanged(distanceFromBottom: 0)
        #expect(scroll.showsJumpToLatest == false)
    }

    // MARK: - 內容被重建或大量增加(#130)

    static func reading() -> ConversationScroll {
        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: 900)
        return scroll
    }

    @Test("跟隨中：內容怎麼變都交給「捲到底」,不另外調整")
    func followingNeedsNoAdjustment() {
        #expect(ConversationScroll().adjustment(from: ["a", "b"], to: ["x", "y"], visible: ["b"]) == .none)
    }

    @Test("閱讀中：只在後面接上(或前面加上舊頁)時不調整，捲動位置不跳")
    func appendingOrPrependingNeedsNoAdjustment() {
        let scroll = Self.reading()
        #expect(scroll.adjustment(from: ["a", "b", "c"], to: ["a", "b", "c", "d", "e"], visible: ["a", "b"]) == .none)
        #expect(scroll.adjustment(from: ["a", "b", "c"], to: ["o", "a", "b", "c"], visible: ["a", "b"]) == .none)
        #expect(scroll.adjustment(from: ["a", "b", "c"], to: ["a", "b", "c"], visible: ["a"]) == .none)
    }

    @Test("閱讀中：內容被重建時，錨定畫面上第一個仍存在的訊息")
    func rebuildAnchorsFirstVisibleMessageThatStillExists() {
        let scroll = Self.reading()
        #expect(scroll.adjustment(from: ["a", "b", "c", "d"], to: ["c", "d", "e"], visible: ["b", "c", "d"]) == .anchor(id: "c"))
        #expect(scroll.adjustment(from: ["a", "b", "c"], to: ["x", "b", "c"], visible: ["b", "c"]) == .anchor(id: "b"))
    }

    @Test("閱讀中：畫面上的訊息都不在了就捲到底，不停在內容之外")
    func rebuildWithoutVisibleMessagesGoesToBottom() {
        let scroll = Self.reading()
        #expect(scroll.adjustment(from: ["a", "b", "c"], to: ["x", "y"], visible: ["a", "b"]) == .bottom)
        #expect(scroll.adjustment(from: ["a", "b", "c"], to: ["x", "y"], visible: []) == .bottom)
    }

    @Test("內容之外：內容比畫面高、可見範圍底緣超過內容底緣一個門檻以上")
    func beyondContent() {
        #expect(Self.measured(offsetY: 56).isBeyondContent == false)
        #expect(Self.measured(offsetY: 56 + 48).isBeyondContent == false)
        #expect(Self.measured(offsetY: 56 + 49).isBeyondContent)
        // 內容高從 3000 縮成 844,捲動位置還留在原處。
        #expect(Self.measured(offsetY: 2000).isBeyondContent)
        // 短到不用捲的對話不算。
        #expect(Self.measured(offsetY: -116, contentHeight: 500).isBeyondContent == false)
    }

    /// #130 review 8:回音被對話紀錄確認(回音換成使用者訊息與回覆)、或送不出被拿掉，都不是重建，不移動讀者的視野。
    @Test("閱讀中：回音被確認或拿掉不算重建，不調整")
    func echoConfirmationIsNotARebuild() {
        let scroll = Self.reading()
        #expect(scroll.adjustment(from: ["a", "b", "echo:1"], to: ["a", "b", "u1", "r1"], visible: ["a", "b"]) == .none)
        #expect(scroll.adjustment(from: ["a", "echo:1", "b"], to: ["a", "b", "u1"], visible: ["a"]) == .none)
        #expect(scroll.adjustment(from: ["a", "b", "echo:1"], to: ["a", "b"], visible: ["a", "b"]) == .none)
        #expect(scroll.adjustment(from: ["a", "b", "echo:1"], to: ["x", "b", "u1"], visible: ["a", "b"]) == .anchor(id: "b"))
    }

    /// #130 review 7:閱讀中，停在內容之外才捲到底只在內容剛被重建後短時間內做;一般排版變化(估算高度變小、reflow、
    /// 鍵盤)不把閱讀中的讀者拉到底。跟隨尾端時一律回到內容(開啟時估算高度收斂，可見範圍會落在內容之外)。
    @Test("內容之外：跟隨中一律回到內容;閱讀中只有內容剛被重建後才切回跟隨並捲到底")
    func returnsToContentOnlyRightAfterRebuild() {
        let now = Date(timeIntervalSince1970: 1_000)
        let beyond = Self.measured(offsetY: 2000)
        #expect(ConversationScroll().returnsToContent(beyond, at: now), "跟隨中")
        #expect(!ConversationScroll().returnsToContent(Self.measured(offsetY: 56), at: now))
        var scroll = Self.reading()
        #expect(!scroll.returnsToContent(beyond, at: now), "沒有重建：排版變化不拉到底")

        scroll.contentChanged(from: ["a", "b"], to: ["a", "b", "c"], at: now)
        #expect(!scroll.returnsToContent(beyond, at: now), "後面接上不是重建")

        scroll.contentChanged(from: ["a", "b"], to: ["x", "y"], at: now)
        #expect(scroll.returnsToContent(beyond, at: now.addingTimeInterval(0.5)))
        #expect(!scroll.returnsToContent(Self.measured(offsetY: 56), at: now.addingTimeInterval(0.5)), "還在內容裡")
        #expect(!scroll.returnsToContent(beyond, at: now.addingTimeInterval(3)), "重建之後過了一段時間")

        scroll.contentChanged(from: ["x", "y"], to: ["p"], at: now)
        scroll.userScrolled(distanceFromBottom: 900)
        #expect(!scroll.returnsToContent(beyond, at: now.addingTimeInterval(0.5)), "使用者自己捲過就不再介入")
    }

    // iPhone 17 實測(#185,唯讀裝置的「需要你」對話):內容只比可見範圍高 6pt,捲到底(−110.3)後系統又把位置
    // 推回內容之外(−10.6,差一個底部 inset),兩邊來回搶，主執行緒滿載。
    static func barelyTaller(offsetY: Double, contentHeight: Double = 664) -> ConversationScrollMetrics {
        ConversationScrollMetrics(
            contentHeight: contentHeight, containerHeight: 658.33, contentOffsetY: offsetY, topInset: 116, bottomInset: 99.75
        )
    }

    @Test("內容高度沒變時，捲回內容後又被推回內容之外：不再搶著捲到底")
    func returningToContentDoesNotFightTheSystemAtTheSameContentHeight() {
        let now = Date(timeIntervalSince1970: 1_000)
        var scroll = ConversationScroll()
        let pushedBeyond = Self.barelyTaller(offsetY: -10.59)
        #expect(scroll.returnsToContent(pushedBeyond, at: now))
        #expect(!scroll.returnsByOffset(pushedBeyond), "第一次捲到最後一列(讓 LazyVStack 排出那一列)")
        scroll.returnedToContent(pushedBeyond)
        #expect(!scroll.returnsToContent(Self.barelyTaller(offsetY: -110.33), at: now))

        // 同一個排版又被推回內容之外：捲到最後一列會多捲一個底部 inset(#251),改以量到的底部位移再捲一次。
        #expect(scroll.returnsToContent(pushedBeyond, at: now), "同一個排版第二次以位移捲回")
        #expect(scroll.returnsByOffset(pushedBeyond))
        scroll.returnedToContent(pushedBeyond)
        #expect(!scroll.returnsToContent(pushedBeyond, at: now), "同一個排版最多兩次，不與系統來回搶")
        #expect(scroll.returnsToContent(Self.barelyTaller(offsetY: 600, contentHeight: 1200), at: now), "內容高度變了照樣捲回")
    }

    // iPhone 17 實測(#191,ledger 長對話、You should know 卡片＋建議列):可見範圍 254pt、位置在底部(距底 0),
    // LazyVStack 卻一列都沒長出來，之後沒有任何排版變化，畫面一直空白。
    static func smallViewport(contentHeight: Double = 48845) -> ConversationScrollMetrics {
        ConversationScrollMetrics(
            contentHeight: contentHeight, containerHeight: 254, contentOffsetY: contentHeight - 254 - 116, topInset: 116, bottomInset: 504
        )
    }

    @Test("跟隨中停在底部卻一列都沒顯示：再捲到底一次;同一個排版只一次")
    func refillsBlankVisibleRangeOncePerContentHeight() {
        var scroll = ConversationScroll()
        let blank = Self.smallViewport()
        #expect(scroll.refillsVisibleRange(blank, visibleRows: 0))
        #expect(!scroll.refillsVisibleRange(blank, visibleRows: 2), "有列在畫面上")

        scroll.returnedToContent(blank)
        #expect(!scroll.refillsVisibleRange(blank, visibleRows: 0), "同一個排版不再捲，不與系統來回搶")
        #expect(scroll.refillsVisibleRange(Self.smallViewport(contentHeight: 46879), visibleRows: 0), "內容高度變了再捲一次")
    }

    @Test("一列都沒顯示但不該介入：閱讀中、可見範圍沒有高度、內容比畫面矮")
    func blankVisibleRangeLeftAloneWhenNotFollowing() {
        let blank = Self.smallViewport()
        #expect(!Self.reading().refillsVisibleRange(blank, visibleRows: 0), "閱讀中不把讀者拉走")
        let collapsed = ConversationScrollMetrics(
            contentHeight: 48845, containerHeight: 0, contentOffsetY: 48729, topInset: 116, bottomInset: 758
        )
        #expect(!ConversationScroll().refillsVisibleRange(collapsed, visibleRows: 0), "可見範圍被擠到沒有高度")
        #expect(!ConversationScroll().refillsVisibleRange(Self.measured(offsetY: -116, contentHeight: 300), visibleRows: 0), "內容不用捲")
    }

    @Test("捲回內容後 inset 變了(輸入列、卡片排好)又停在內容之外：照樣捲回")
    func returnsAgainWhenInsetsChangeAtTheSameContentHeight() {
        let now = Date(timeIntervalSince1970: 1_000)
        var scroll = ConversationScroll()
        // iPhone 17 實測(#191):第一次排版還沒有 inset 時就捲過一次，排好 inset 後 `scrollTo(edge: .bottom)` 多捲一個底部 inset。
        let beforeInsets = ConversationScrollMetrics(contentHeight: 41209, containerHeight: 174, contentOffsetY: 41035, topInset: 0, bottomInset: 0)
        scroll.returnedToContent(beforeInsets)
        let pushedBeyond = ConversationScrollMetrics(contentHeight: 41209, containerHeight: 174, contentOffsetY: 41389, topInset: 116, bottomInset: 470)
        #expect(scroll.returnsToContent(pushedBeyond, at: now))
    }

    @Test("一直沒有列長出來(兩種排版來回跳)：再捲有次數上限，不與系統來回搶;有列顯示過就重新計算")
    func refillingIsBoundedWhenRowsNeverAppear() {
        var scroll = ConversationScroll()
        // iPhone 17 實測(#191,軟體鍵盤叫出):內容高在兩個值之間來回跳，每次都一列沒有。
        let layoutA = Self.smallViewport(contentHeight: 29099)
        let layoutB = Self.smallViewport(contentHeight: 29141)
        var refills = 0
        for metrics in Array(repeating: [layoutA, layoutB], count: 10).joined() where scroll.refillsVisibleRange(metrics, visibleRows: 0) {
            scroll.returnedToContent(metrics)
            refills += 1
        }
        #expect(refills == ConversationScroll.maximumRefills)

        scroll.visibleRowsChanged(count: 3)
        // 有列顯示過、可見範圍又變了(鍵盤收起、輸入列改變)之後空白就再捲;只有內容估算高度來回跳則受連續捲回上限限制(#251)。
        let resized = ConversationScrollMetrics(contentHeight: 29300, containerHeight: 300, contentOffsetY: 29300 - 300 - 116, topInset: 116, bottomInset: 458)
        #expect(scroll.refillsVisibleRange(resized, visibleRows: 0), "有列顯示過，可見範圍變了之後又空白就再捲")
    }

    @Test("捲回內容後兩種排版輪流出現、每次都在內容之外：捲回有次數上限;內容變了或使用者自己捲過就重新計算")
    func returningToContentIsBoundedWhenTwoLayoutsAlternate() {
        let now = Date(timeIntervalSince1970: 1_000)
        var scroll = ConversationScroll()
        // iPhone 17 實測(#251,ledger 對話打 `!git status`,軟體鍵盤＋註記一行＋! 指令提示):LazyVStack 的內容高
        // 在 618 與 664 之間來回跳，每次捲到最後一列後又停在內容之外;只記上一次的排版擋不住兩個排版輪流，主執行緒滿載。
        let layoutA = ConversationScrollMetrics(contentHeight: 618, containerHeight: 195.33, contentOffsetY: 869.33, topInset: 116, bottomInset: 562.67)
        let layoutB = ConversationScrollMetrics(contentHeight: 664, containerHeight: 195.33, contentOffsetY: 869.33, topInset: 116, bottomInset: 562.67)
        var returns = 0
        for metrics in Array(repeating: [layoutA, layoutB], count: 10).joined() where scroll.returnsToContent(metrics, at: now) {
            scroll.returnedToContent(metrics)
            returns += 1
        }
        #expect(returns == ConversationScroll.maximumReturns)

        // 另一個排版：不受「同一個排版只捲一次」影響，只看次數。
        let layoutC = ConversationScrollMetrics(contentHeight: 710, containerHeight: 195.33, contentOffsetY: 869.33, topInset: 116, bottomInset: 562.67)
        #expect(!scroll.returnsToContent(layoutC, at: now), "到了上限")
        scroll.contentChanged(from: ["a"], to: ["a", "b"], at: now)
        #expect(scroll.returnsToContent(layoutC, at: now), "有新的列：照樣捲回")
        for metrics in Array(repeating: [layoutA, layoutB], count: 10).joined() where scroll.returnsToContent(metrics, at: now) {
            scroll.returnedToContent(metrics)
        }
        #expect(!scroll.returnsToContent(layoutC, at: now), "又到了上限")
        scroll.userScrolled(distanceFromBottom: 0)
        #expect(scroll.returnsToContent(layoutC, at: now), "使用者自己捲過：重新計算")
        for metrics in Array(repeating: [layoutA, layoutB], count: 10).joined() where scroll.returnsToContent(metrics, at: now) {
            scroll.returnedToContent(metrics)
        }
        #expect(!scroll.returnsToContent(layoutC, at: now), "第三次到了上限")
        // 不是對話項目的新內容(slash 面板卡片、需要你、工作中指示):畫面捲去跟隨時也重新計算，否則新的列排不出來(#251)。
        scroll.followedNewContent()
        #expect(scroll.returnsToContent(layoutC, at: now), "跟隨新內容：重新計算")
    }

    @Test("可見列數在 0 與有列之間來回跳：再捲也受連續捲回上限限制")
    func refillingIsBoundedWhenRowsFlicker() {
        var scroll = ConversationScroll()
        // iPhone 17 實測(#251,`!git status` 後):每次捲到底，列長出來又消失，`visibleRowsChanged` 一直把再捲的次數歸零。
        let layoutA = Self.smallViewport(contentHeight: 618)
        let layoutB = Self.smallViewport(contentHeight: 664)
        var refills = 0
        for metrics in Array(repeating: [layoutA, layoutB], count: 10).joined() {
            guard scroll.refillsVisibleRange(metrics, visibleRows: 0) else { continue }
            scroll.returnedToContent(metrics)
            scroll.visibleRowsChanged(count: 2)
            refills += 1
        }
        #expect(refills == ConversationScroll.maximumReturns)
    }

    @Test("以位移捲到底：ScrollPosition 的 y 從內容頂端量起，不含頂部 inset")
    func bottomScrollPosition() {
        // iPhone 17 實測(#251,AX5 開啟需要你的對話):內容 927、可見範圍 616、頂部 inset 116,`scrollTo(y: 195)`
        // 之後 contentOffset 是 79(少了一個頂部 inset,距底 116pt)。
        let metrics = ConversationScrollMetrics(contentHeight: 927, containerHeight: 616, contentOffsetY: 337, topInset: 116, bottomInset: 140)
        #expect(metrics.bottomScrollPositionY == 311, "捲到這裡 contentOffset 是 195,距底 0")
        let short = ConversationScrollMetrics(contentHeight: 100, containerHeight: 215, contentOffsetY: 0, topInset: 116, bottomInset: 543)
        #expect(short.bottomScrollPositionY == 0, "內容不用捲：停在頂端")
    }

    @Test("以位移捲回後內容高度又變、畫面不在底部：以新的底部位移再捲，次數有上限")
    func followsByOffsetAfterReturningByOffset() {
        var scroll = ConversationScroll()
        // iPhone 17 實測(#251,AX5 開啟需要你的對話):以位移捲過後 ScrollPosition 停在那個位移，那裡的列排出實際高度、
        // 內容從 927 一路變成 2866,畫面停在對話中間，需要你卡片一直在畫面外。
        let pushedBeyond = Self.barelyTaller(offsetY: -10.59)
        let grown = Self.barelyTaller(offsetY: -110.33, contentHeight: 2000)
        scroll.returnedToContent(pushedBeyond)
        #expect(!scroll.followsByOffset(grown), "還沒以位移捲過")
        scroll.returnedToContent(pushedBeyond)
        #expect(!scroll.followsByOffset(Self.barelyTaller(offsetY: -200)), "內容高度沒變(捲動途中的位置)")
        #expect(scroll.followsByOffset(grown), "內容長高、距底 1336pt")
        scroll.followedByOffset(grown)
        #expect(!scroll.followsByOffset(grown), "同一個內容高度只捲一次")
        var follows = 1
        for height in stride(from: 2100.0, through: 3000, by: 100) {
            let metrics = Self.barelyTaller(offsetY: 0, contentHeight: height)
            guard scroll.followsByOffset(metrics) else { continue }
            scroll.followedByOffset(metrics)
            follows += 1
        }
        #expect(follows == ConversationScroll.maximumOffsetFollows, "高度一直變也有上限")
    }

    @Test("以位移捲回後可見範圍變小(停止列出現、輸入卡片長高)、內容高度沒變：以新的底部位移再捲")
    func followsByOffsetWhenContainerShrinks() {
        var scroll = ConversationScroll()
        // iPhone 17 實測(#251,AX5 開啟工作中的 Codex 對話):以位移捲到底後停止列出現，可見範圍變小、底部 inset 變大，
        // 內容高度不變;ScrollPosition 停在原來的位移，「Writing…」被壓到輸入卡片底下。
        let pushedBeyond = Self.barelyTaller(offsetY: -10.59)
        scroll.returnedToContent(pushedBeyond)
        scroll.returnedToContent(pushedBeyond)
        let shrunk = ConversationScrollMetrics(contentHeight: 664, containerHeight: 560, contentOffsetY: -110.33, topInset: 116, bottomInset: 198)
        #expect(scroll.followsByOffset(shrunk), "距底 98pt,最後一列在輸入卡片底下")
        scroll.followedByOffset(shrunk)
        // 實測：停止列出現後內容 676、可見範圍 511.33、底部 inset 246.67,距底 36.67pt(比「在底部」的門檻 48pt 小),
        // 「Writing…」下半被輸入卡片蓋住。以位移捲就是要貼齊底部，差 1pt 以上就再捲。
        let slightlyShort = ConversationScrollMetrics(contentHeight: 676, containerHeight: 511.33, contentOffsetY: 12, topInset: 116, bottomInset: 246.67)
        #expect(scroll.followsByOffset(slightlyShort), "距底 36.67pt")
    }

    @Test("以位移捲回後使用者自己捲走或內容在底部：不再以位移捲")
    func doesNotFollowByOffsetAfterUserScrolledOrAtBottom() {
        var scroll = ConversationScroll()
        let pushedBeyond = Self.barelyTaller(offsetY: -10.59)
        scroll.returnedToContent(pushedBeyond)
        scroll.returnedToContent(pushedBeyond)
        #expect(!scroll.followsByOffset(Self.barelyTaller(offsetY: 2000 - 658.33 - 116, contentHeight: 2000)), "已經在底部")
        scroll.userScrolled(distanceFromBottom: 600)
        #expect(!scroll.followsByOffset(Self.barelyTaller(offsetY: 0, contentHeight: 2000)))
    }

    @Test("可見範圍不到一列高(軟體鍵盤＋卡片擠掉)：不再捲，畫不出任何列")
    func noRefillBelowOneRow() {
        let squeezed = ConversationScrollMetrics(contentHeight: 29099, containerHeight: 6, contentOffsetY: 28869, topInset: 116, bottomInset: 752)
        #expect(!ConversationScroll().refillsVisibleRange(squeezed, visibleRows: 0))
        let squeezedBeyond = ConversationScrollMetrics(contentHeight: 29390, containerHeight: 6, contentOffsetY: 29653, topInset: 116, bottomInset: 752)
        #expect(!ConversationScroll().returnsToContent(squeezedBeyond, at: Date(timeIntervalSince1970: 1_000)), "停在內容之外也不捲")
    }
}
