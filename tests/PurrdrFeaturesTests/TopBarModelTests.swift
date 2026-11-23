import Foundation
import PurrdrFeatures
import Testing

@Suite("共用頂列的邏輯(#499)")
struct TopBarModelTests {
    @Test("右側動作依 tab 決定:聊天新增聊天、檔案上傳、主機新增主機;流量沒有;設定沒有頂列")
    func plusDependsOnTab() {
        #expect(TopLevelTab.chats.topBar?.plus == .newChat)
        #expect(TopLevelTab.files.topBar?.plus == .upload)
        #expect(TopLevelTab.hosts.topBar?.plus == .addHost)
        #expect(TopLevelTab.traffic.topBar != nil)
        #expect(TopLevelTab.traffic.topBar?.plus == nil)
        #expect(TopLevelTab.settings.topBar == nil)
    }

    @Test("控制項形狀:聊天是膠囊(電腦圖示｜＋),檔案只有＋,主機只有＋,流量只有電腦圖示")
    func controlsShape() {
        #expect(TopLevelTab.chats.topBar?.controls == .pill)
        #expect(TopLevelTab.files.topBar?.controls == .plusOnly)
        #expect(TopLevelTab.hosts.topBar?.controls == .plusOnly)
        #expect(TopLevelTab.traffic.topBar?.controls == .hostScopeOnly)
    }

    @Test("只有聊天與流量有主機範圍;主機 tab 本身是清單、檔案沒有主機範圍")
    func hostScopeDependsOnTab() {
        #expect(TopLevelTab.chats.topBar?.hasHostScope == true)
        #expect(TopLevelTab.traffic.topBar?.hasHostScope == true)
        #expect(TopLevelTab.files.topBar?.hasHostScope == false)
        #expect(TopLevelTab.hosts.topBar?.hasHostScope == false)
    }

    @Test("有搜尋的 tab(聊天、檔案)收成搜尋膠囊;其餘收成置中小標題膠囊")
    func collapsedStyle() {
        #expect(TopLevelTab.chats.topBar?.hasSearch == true)
        #expect(TopLevelTab.chats.topBar?.collapsed == .searchCapsule)
        #expect(TopLevelTab.files.topBar?.collapsed == .searchCapsule)
        #expect(TopLevelTab.hosts.topBar?.hasSearch == false)
        #expect(TopLevelTab.hosts.topBar?.collapsed == .smallTitleCapsule)
        #expect(TopLevelTab.traffic.topBar?.collapsed == .smallTitleCapsule)
    }

    @Test("沒篩選主機沒有小圓點、念「所有主機」;篩選某台有小圓點、念主機名")
    func hostScopeDot() {
        let all = TopBarHostScope(filteredHostName: nil)
        #expect(!all.showsDot)
        #expect(all.accessibilityLabel == "Showing: All Hosts")
        let one = TopBarHostScope(filteredHostName: "Studio Mac")
        #expect(one.showsDot)
        #expect(one.accessibilityLabel == "Showing: Studio Mac")
    }

    @Test("標題列與內容起點照設計稿:預設字級標題列 52、有搜尋內容起點 106、沒搜尋 62")
    func layoutAtDefaultSize() {
        let search = TopBarLayout(hasSearch: true)
        #expect(search.titleSize == 34)
        #expect(search.titleRowHeight == 52)
        #expect(search.searchHeight == 40)
        #expect(search.contentInset == 106)
        #expect(TopBarLayout(hasSearch: false).contentInset == 62)
    }

    @Test("字級放大:標題最多放大 1.5 倍、列高取 max(52, 字級 × 1.2)、搜尋欄最多 1.45 倍")
    func layoutScalesWithCaps() {
        let big = TopBarLayout(hasSearch: true, typeScale: 3)
        #expect(big.titleSize == 51)
        #expect(abs(big.titleRowHeight - 61.2) < 0.001)
        #expect(abs(big.searchHeight - 58) < 0.001)
        let mid = TopBarLayout(hasSearch: true, typeScale: 1.4)
        #expect(abs(mid.titleSize - 47.6) < 0.001)
        #expect(abs(mid.titleRowHeight - 57.12) < 0.001)
        #expect(TopBarLayout(hasSearch: true, typeScale: 0.8).titleRowHeight == 52)
    }

    @Test("搜尋欄隨進度上移:未收合在標題列下 4pt、收合貼頂 4pt 且高 44")
    func searchMovesToTop() {
        let layout = TopBarLayout(hasSearch: true)
        #expect(layout.searchTop(progress: 0) == 56)
        #expect(layout.searchHeight(progress: 0) == 40)
        #expect(layout.searchTop(progress: 1) == 4)
        #expect(layout.searchHeight(progress: 1) == 44)
        #expect(layout.searchTop(progress: 0.5) == 30)
    }

    @Test("捲動 56pt 內收合完成:進度 0…1、超過不再變、往回捲(橡皮筋)不小於 0")
    func scrollProgress() {
        #expect(TopBarScroll(offset: 0).progress == 0)
        #expect(TopBarScroll(offset: 28).progress == 0.5)
        #expect(TopBarScroll(offset: 56).progress == 1)
        #expect(TopBarScroll(offset: 400).progress == 1)
        #expect(TopBarScroll(offset: -30).progress == 0)
        #expect(!TopBarScroll(offset: 55).isCollapsed)
        #expect(TopBarScroll(offset: 56).isCollapsed)
    }

    @Test("標題列隨進度淡出並上移 26pt")
    func titleFades() {
        #expect(TopBarScroll(offset: 0).titleOpacity == 1)
        #expect(TopBarScroll(offset: 0).titleOffset == 0)
        #expect(TopBarScroll(offset: 28).titleOpacity == 0.5)
        #expect(TopBarScroll(offset: 56).titleOpacity == 0)
        #expect(TopBarScroll(offset: 56).titleOffset == -26)
    }
}
