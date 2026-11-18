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
        #expect(scroll.showsJumpToLatest == false)
        #expect(scroll.autoScrollsOnNewContent)
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

    @Test("新訊息跟隨：在底部時新內容撐開距離，按鈕不閃現")
    func newContentWhileFollowingHidesJumpToLatest() {
        var scroll = ConversationScroll()
        scroll.userScrolled(distanceFromBottom: Self.measured(offsetY: 56).distanceFromBottom)
        scroll.layoutChanged(distanceFromBottom: Self.measured(offsetY: 56, contentHeight: 1244).distanceFromBottom)
        #expect(scroll.autoScrollsOnNewContent)
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
        scroll.returnedToContent(pushedBeyond)
        #expect(!scroll.returnsToContent(Self.barelyTaller(offsetY: -110.33), at: now))

        #expect(!scroll.returnsToContent(pushedBeyond, at: now), "同一個內容高度只捲回一次")
        #expect(scroll.returnsToContent(Self.barelyTaller(offsetY: 600, contentHeight: 1200), at: now), "內容高度變了照樣捲回")
    }
}
