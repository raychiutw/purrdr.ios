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
}
