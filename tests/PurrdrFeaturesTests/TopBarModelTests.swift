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

    @Test("只有聊天與檔案有搜尋(系統 searchable);主機與流量沒有")
    func searchTabs() {
        #expect(TopLevelTab.chats.topBar.hasSearch == true)
        #expect(TopLevelTab.files.topBar.hasSearch == true)
        #expect(TopLevelTab.hosts.topBar.hasSearch == false)
        #expect(TopLevelTab.traffic.topBar.hasSearch == false)
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
}
