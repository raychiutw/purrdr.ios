import Foundation
import PurrdrFeatures
import Testing

@Suite("共用頂列的邏輯(#499)")
struct TopBarModelTests {
    @Test("右側動作依 tab 決定:聊天新增聊天、檔案上傳、主機新增主機;流量沒有")
    func plusDependsOnTab() {
        #expect(TopLevelTab.chats.topBar.plus == .newChat)
        #expect(TopLevelTab.files.topBar.plus == .upload)
        #expect(TopLevelTab.hosts.topBar.plus == .addHost)
        #expect(TopLevelTab.traffic.topBar.plus == nil)
    }

    @Test("控制項形狀:聊天與檔案是膠囊(電腦圖示｜＋),主機只有＋,流量只有電腦圖示(#500)")
    func controlsShape() {
        #expect(TopLevelTab.chats.topBar.controls == .pill)
        #expect(TopLevelTab.files.topBar.controls == .pill)
        #expect(TopLevelTab.hosts.topBar.controls == .plusOnly)
        #expect(TopLevelTab.traffic.topBar.controls == .hostScopeOnly)
    }

    @Test("聊天、檔案與流量有主機範圍(電腦圖示);主機 tab 本身是清單,沒有")
    func hostScopeDependsOnTab() {
        #expect(TopLevelTab.chats.topBar.hasHostScope == true)
        #expect(TopLevelTab.traffic.topBar.hasHostScope == true)
        #expect(TopLevelTab.files.topBar.hasHostScope == true)
        #expect(TopLevelTab.hosts.topBar.hasHostScope == false)
    }

    @Test("有搜尋的 tab(聊天、檔案)收成搜尋膠囊;其餘收成置中小標題膠囊")
    func collapsedStyle() {
        #expect(TopLevelTab.chats.topBar.hasSearch == true)
        #expect(TopLevelTab.chats.topBar.collapsed == .searchCapsule)
        #expect(TopLevelTab.files.topBar.collapsed == .searchCapsule)
        #expect(TopLevelTab.hosts.topBar.hasSearch == false)
        #expect(TopLevelTab.hosts.topBar.collapsed == .smallTitleCapsule)
        #expect(TopLevelTab.traffic.topBar.collapsed == .smallTitleCapsule)
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

    @Test("檔案的電腦圖示是「這頁看哪台」:沒有篩選小圓點、念「主機:名稱」(#500)")
    func selectedHostHasNoDot() {
        let scope = TopBarHostScope.selected(hostName: "Studio Mac")
        #expect(!scope.showsDot)
        #expect(scope.accessibilityLabel == "Host: Studio Mac")
        #expect(TopBarHostScope.selected(hostName: nil).accessibilityLabel == "Host")
    }

    @Test("版面的關係(不抄設計稿數字):標題列至少一個控制項高、內容起點在標題列(與搜尋欄)之下、有搜尋的比沒搜尋的低")
    func layoutRelationships() {
        let search = TopBarLayout(hasSearch: true)
        let plain = TopBarLayout(hasSearch: false)
        #expect(search.titleRowHeight >= TopBarMetrics.controlHeight, "標題列放不下 44pt 的控制項")
        #expect(search.contentInset > search.titleRowHeight + search.searchHeight, "內容起點壓到搜尋欄")
        #expect(plain.contentInset > plain.titleRowHeight, "內容起點壓到標題列")
        #expect(search.contentInset > plain.contentInset)
        #expect(search.searchHeight >= TopBarMetrics.collapsedSearchHeight - 8, "搜尋欄比收合後的膠囊小太多,收合時會跳一大段")
    }

    @Test("字級放大:版面單調變大、有上限、不比預設小(標題與搜尋欄各有放大上限)")
    func layoutScalesMonotonicallyWithCaps() {
        let scales: [CGFloat] = [0.8, 1, 1.2, 1.4, 2, 3, 6]
        let layouts = scales.map { TopBarLayout(hasSearch: true, typeScale: $0) }
        for (small, large) in zip(layouts, layouts.dropFirst()) {
            #expect(large.titleSize >= small.titleSize)
            #expect(large.titleRowHeight >= small.titleRowHeight)
            #expect(large.searchHeight >= small.searchHeight)
            #expect(large.contentInset >= small.contentInset)
        }
        let base = TopBarLayout(hasSearch: true)
        #expect(layouts[0].titleRowHeight == base.titleRowHeight, "字級縮小時標題列不該變矮(有最小高度)")
        // 上限:再放大也不超過上限倍率。
        let huge = TopBarLayout(hasSearch: true, typeScale: 100)
        #expect(huge.titleSize <= base.titleSize * TopBarMetrics.titleScaleCap + 0.001)
        #expect(huge.searchHeight <= base.searchHeight * TopBarMetrics.searchScaleCap + 0.001)
        #expect(huge.titleSize == layouts.last?.titleSize)
    }

    @Test("搜尋欄隨進度單調上移、收合時貼近頂端且是 44pt 的玻璃膠囊高度")
    func searchMovesTowardTop() {
        let layout = TopBarLayout(hasSearch: true)
        let steps: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        let tops = steps.map { layout.searchTop(progress: $0) }
        for (earlier, later) in zip(tops, tops.dropFirst()) { #expect(later < earlier, "搜尋欄沒有隨進度上移") }
        #expect(tops.first! >= layout.titleRowHeight, "未收合時搜尋欄應在標題列下面")
        #expect(tops.last! == TopBarMetrics.collapsedSearchTop)
        #expect(layout.searchHeight(progress: 1) == TopBarMetrics.collapsedSearchHeight)
        #expect(layout.searchHeight(progress: 0) == layout.searchHeight)
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

    @Test("標題列隨進度單調淡出並上移;收合時完全透明,往回捲(橡皮筋)不放大")
    func titleFadesMonotonically() {
        let offsets: [CGFloat] = [-30, 0, 14, 28, 42, 56, 400]
        let scrolls = offsets.map { TopBarScroll(offset: $0) }
        for (earlier, later) in zip(scrolls, scrolls.dropFirst()) {
            #expect(later.titleOpacity <= earlier.titleOpacity)
            #expect(later.titleOffset <= earlier.titleOffset)
        }
        #expect(TopBarScroll(offset: 0).titleOpacity == 1)
        #expect(TopBarScroll(offset: 0).titleOffset == 0)
        #expect(TopBarScroll(offset: -30).titleOpacity == 1)
        #expect(TopBarScroll(offset: TopBarMetrics.collapseDistance).titleOpacity == 0)
        #expect(TopBarScroll(offset: 400).titleOffset == -TopBarMetrics.titleLift)
    }
}
