import Foundation
import Testing

/// 列尾 > 一律 push 的原始碼守門(#619、spec #612):入口不再用 sheet 開、Plus 功能列不換成帳號 sheet、
/// 會開選單的列用 ⋯ 而不是 >、功能列的 > 由系統 NavigationLink 給而不是自己畫。
@Suite("列尾 > 一律 push")
struct ChevronPushUsageTests {
    private static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: featuresFolder.appending(path: name), encoding: .utf8)
    }

    @Test("版面圖是下一頁,不是 sheet")
    func layoutIsPushed() throws {
        let layout = try Self.source("SpacesLayoutView.swift")
        #expect(!layout.contains("SpacesLayoutSheet"), "版面圖不再是 sheet")
        #expect(!layout.contains("SheetCloseToolbar"), "下一頁左上是系統返回,不放關閉鈕")
        #expect(layout.contains("struct SpacesLayoutPage"))
        let list = try Self.source("AgentListView.swift")
        #expect(!list.contains(".sheet(isPresented: $showsLayout"), "聊天的「顯示版面」要 push")
        #expect(list.contains(".navigationDestination(isPresented: $showsLayout)"))
        let actions = try Self.source("WorkspaceActionsViews.swift")
        #expect(!actions.contains("case layout("), "列表的版面圖不再走 sheet 列舉")
        #expect(!actions.contains("navigationDestination(item:"), "版面圖與聊天只用路徑的單一目的地機制(#641)")
        #expect(actions.contains("navigationDestination(for: ChatsDestination.self)"))
        let spaces = try Self.source("SpacesListView.swift")
        #expect(!spaces.contains("presentation.sheet = .layout"))
        #expect(spaces.contains("NavigationLink(value: ChatsDestination.layout("), "多 Pane 的 Tab 列是系統 NavigationLink")
        #expect(!spaces.contains("\"chevron.right\""), "列尾的 > 由 NavigationLink 給,不自己放")
        #expect(!spaces.contains("presentation.layoutRoute"), "Tab 列不再用 Button 設 layoutRoute")
    }

    @Test("聊天 tab 窄視窗是 NavigationStack(path:),列表不帶 selection")
    func chatsStackUsesPath() throws {
        let top = try Self.source("TopNavigationView.swift")
        #expect(top.contains("NavigationStack(path: $navigation.chatsPath)"))
        #expect(!top.contains(".navigationDestination(item: $navigation.selectedChat)"), "item 與 value 不混用")
        let list = try Self.source("AgentListView.swift")
        #expect(list.contains("window != nil && listSizeClass != .compact"), "窄視窗的 List 不能有 selection(push 後第一下返回會被吃掉)")
    }

    @Test("流量主機明細是下一頁,不是 sheet")
    func dataUsageHostDetailIsPushed() throws {
        let text = try Self.source("DataUsageView.swift")
        #expect(!text.contains("DataUsageHostSheet"))
        #expect(!text.contains("detailHostID"))
        #expect(text.contains("NavigationLink(value: DataUsageHostRoute("))
        #expect(text.contains(".navigationDestination(for: DataUsageHostRoute.self)"))
    }

    @Test("Plus 功能列推入對應頁,不換成帳號 sheet,也不自己畫 >")
    func plusFeatureRowsPush() throws {
        let plus = try Self.source("PlusView.swift")
        #expect(plus.contains("NavigationLink(value: feature)"))
        #expect(!plus.contains("\"chevron.right\""), "> 由 NavigationLink 給")
        let top = try Self.source("TopNavigationView.swift")
        #expect(!top.contains("navigation.sheet = .member }))"), "付費牆的功能列不再換成帳號 sheet")
        let links = try Self.source("PlusFeatures.swift")
        #expect(!links.contains("dismissesOnOpen"))
    }

    @Test("會開選單的通知裝置列用 ⋯,不用 >")
    func menuRowsUseEllipsis() throws {
        let text = try Self.source("PushDevicesSection.swift")
        #expect(!text.contains("\"chevron.right\""))
        #expect(text.contains("\"ellipsis\""))
    }
}
