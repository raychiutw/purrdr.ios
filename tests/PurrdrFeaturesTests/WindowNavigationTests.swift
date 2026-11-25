import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import Testing

/// 列表合併了所有主機(#39):聊天以主機 + pane id 識別。
private func route(_ paneID: String, host: HostSelection = .demo) -> ChatRoute { ChatRoute(host: host, paneID: paneID) }

/// iPad 每個視窗各自的導覽狀態(#31):兩欄的選取、鍵盤快捷鍵。
@MainActor
@Suite("視窗導覽")
struct WindowNavigationTests {
    private let visible = [route("w2:p1"), route("w1:p1"), route("w3:p1")]
    private static let other = HostSelection.host(UUID(uuidString: "5EED0000-0000-4000-8000-000000000002")!)


    @Test("下一個 Agent:沒選取時選第一個，之後依列表順序往下，到底停在最後一個")
    func nextAgentFollowsListOrder() {
        let model = TopNavigationModel()

        model.perform(.nextAgent, visibleAgents: visible)
        #expect(model.selectedChat == route("w2:p1"))
        model.perform(.nextAgent, visibleAgents: visible)
        #expect(model.selectedChat == route("w1:p1"))
        model.perform(.nextAgent, visibleAgents: visible)
        model.perform(.nextAgent, visibleAgents: visible)
        #expect(model.selectedChat == route("w3:p1"))
    }

    @Test("上一個 Agent:沒選取時選最後一個，到頂停在第一個")
    func previousAgentFollowsListOrder() {
        let model = TopNavigationModel()

        model.perform(.previousAgent, visibleAgents: visible)
        #expect(model.selectedChat == route("w3:p1"))
        model.perform(.previousAgent, visibleAgents: visible)
        model.perform(.previousAgent, visibleAgents: visible)
        model.perform(.previousAgent, visibleAgents: visible)
        #expect(model.selectedChat == route("w2:p1"))
    }

    @Test("選取的 Agent 被搜尋濾掉時，下一個從列表頂端開始")
    func nextAgentAfterSelectionFilteredOut() {
        let model = TopNavigationModel()
        model.selectedChat = route("w9:p1")

        model.perform(.nextAgent, visibleAgents: visible)

        #expect(model.selectedChat == route("w2:p1"))
    }

    @Test("列表是空的時，切換 Agent 不改變選取")
    func switchingAgentWithEmptyList() {
        let model = TopNavigationModel()
        model.selectedChat = route("w1:p1")

        model.perform(.nextAgent, visibleAgents: [])

        #expect(model.selectedChat == route("w1:p1"))
    }

    @Test("兩個視窗各有自己的導覽狀態：一個視窗選了 Agent、開了 sheet,另一個不受影響")
    func windowsHaveIndependentNavigation() {
        let first = TopNavigationModel()
        let second = TopNavigationModel()

        first.perform(.nextAgent, visibleAgents: visible)
        first.perform(.settings, visibleAgents: visible)

        #expect(first.selectedChat == route("w2:p1"))
        #expect(first.sheet == .member)
        #expect(first.tab == .chats)
        #expect(second.sheet == nil)
        #expect(second.selectedChat == nil)
        #expect(second.tab == .chats)
    }

    @Test("搜尋快捷鍵讓搜尋欄取得焦點")
    func searchFocusesSearchField() {
        let model = TopNavigationModel()

        model.perform(.search, visibleAgents: visible)

        #expect(model.isSearchFocused)
    }

    @Test("開終端機快捷鍵打開選取中 Agent 的 Pane 終端機;沒選取時不做事")
    func openTerminalOpensSelectedAgentsPane() {
        let model = TopNavigationModel()

        model.perform(.openTerminal, visibleAgents: visible)
        #expect(model.openedTerminal == nil)

        model.selectedChat = route("w1:p1")
        model.perform(.openTerminal, visibleAgents: visible)
        #expect(model.openedTerminal == route("w1:p1"))
    }

    @Test("換選別的 Agent 時，前一個 Agent 開著的終端機收起")
    func selectingAnotherAgentClosesTerminal() {
        let model = TopNavigationModel()
        model.selectedChat = route("w1:p1")
        model.perform(.openTerminal, visibleAgents: visible)

        model.perform(.nextAgent, visibleAgents: visible)

        #expect(model.selectedChat == route("w3:p1"))
        #expect(model.openedTerminal == nil)
    }

    // MARK: Spaces 與選取

    private static let snapshot = HostSnapshot(
        version: "0.9.5",
        workspaces: [Workspace(id: "w1", number: 1, label: "ledger"), Workspace(id: "w2", number: 2, label: "weather-app")],
        agents: [
            Agent(paneID: "w1:p1", workspaceID: "w1", kind: "claude", status: .done),
            Agent(paneID: "w1:p2", workspaceID: "w1", kind: "codex", status: .blocked),
            Agent(paneID: "w2:p1", workspaceID: "w2", kind: "claude", status: .blocked),
        ])

    /// Spaces 的段落(#501):w2 一個 Agent Tab、w1 一個 Agent Tab、一個多 pane 的 Tab 與一個終端機 Tab。
    private static let sections = [
        space("w2", tabs: [tab("w2:p1")]),
        space("w1", tabs: [tab("w1:p2"), tab("w1:p1"), layoutTab("w1:tX", in: "w1"), terminalTab("w1:p9")]),
    ]

    private static func space(_ workspaceID: String, host: HostSelection = .demo, tabs: [SpacesTab]) -> SpacesSection {
        SpacesSection(host: host, hostName: "Demo", hostIcon: .default, workspaceID: workspaceID, workspace: workspaceID, tabs: tabs)
    }

    private static func tab(_ paneID: String, host: HostSelection = .demo) -> SpacesTab {
        SpacesTab(
            host: host, key: paneID, title: paneID, target: .pane(route(paneID, host: host)), avatar: .agent(kind: "claude", status: .idle))
    }

    private static func layoutTab(_ tabID: String, in workspaceID: String) -> SpacesTab {
        SpacesTab(
            host: .demo, key: tabID, title: tabID, target: .layout(workspaceID: workspaceID, tabID: tabID),
            avatar: .agent(kind: "claude", status: .idle))
    }

    private static func terminalTab(_ paneID: String) -> SpacesTab {
        SpacesTab(host: .demo, key: paneID, title: paneID, target: .pane(route(paneID)), avatar: .terminal)
    }

    @Test("列表沒有 workspace 篩選:快捷鍵切換 Agent 依 Spaces 的畫面順序,含所有主機,只含單一 Pane 的 Agent Tab(不含終端機與多 pane 的 Tab)")
    func visibleAgentsFollowSpacesOrderAcrossHosts() {
        let model = TopNavigationModel()
        let sections = Self.sections + [Self.space("w2", host: Self.other, tabs: [Self.tab("w2:p1", host: Self.other)])]

        #expect(
            model.visibleAgents(sections)
                == [route("w2:p1"), route("w1:p2"), route("w1:p1"), route("w2:p1", host: Self.other)])
    }

    @Test("兩欄:切到別的 tab 再回聊天,這個視窗選的聊天與開著的終端機還在")
    func selectionSurvivesTabSwitches() {
        let model = TopNavigationModel()
        model.selectedChat = route("w1:p1")
        model.perform(.openTerminal, visibleAgents: visible)

        model.tab = .files
        model.tab = .chats

        #expect(model.selectedChat == route("w1:p1"))
        #expect(model.openedTerminal == route("w1:p1"))
    }

    @Test("兩欄:點新增主機換到主機 tab,不清掉選的聊天")
    func openingAddHostKeepsSelectedChat() {
        let model = TopNavigationModel()
        model.selectedChat = route("w1:p1")

        model.openAddHost()

        #expect(model.tab == .hosts)
        #expect(model.selectedChat == route("w1:p1"))
    }

    // MARK: 在新視窗開啟

    @Test("在新視窗開啟的 Agent 記下主機：重新啟動還原視窗時，編碼後內容不變")
    func paneWindowSurvivesRestoration() throws {
        let window = PaneWindow(kind: .chat, host: .demo, paneID: "w1:p1", sessionID: "s-1", title: "Tidy up the CSV export")

        let restored = try JSONDecoder().decode(PaneWindow.self, from: JSONEncoder().encode(window))

        #expect(restored == window)
        #expect(restored.host == .demo)
    }

    @Test("新視窗可以開任何一台主機的聊天(每台主機各自連線,#39);主機已移除時沒有內容")
    func paneWindowOpensAnyKnownHost() throws {
        let id = try #require(UUID(uuidString: "5EED0000-0000-4000-8000-000000000001"))
        let window = PaneWindow(kind: .terminal, host: .host(id), paneID: "w1:p1", sessionID: nil, title: "ledger")
        let demo = PaneWindow(kind: .chat, host: .demo, paneID: "w1:p1", sessionID: nil, title: "ledger")

        #expect(window.route(hostIDs: [id]) == ChatRoute(host: .host(id), paneID: "w1:p1"))
        #expect(window.route(hostIDs: []) == nil)
        #expect(demo.route(hostIDs: []) == ChatRoute(host: .demo, paneID: "w1:p1"))
    }

    // MARK: 視窗細節(#519)

    @Test("Pane 視窗標題是「Agent 名稱 · 主機」;沒有主機名稱時只有 Agent 名稱")
    func paneWindowTitleIncludesHostName() {
        let window = PaneWindow(kind: .chat, host: .demo, paneID: "w1:p1", sessionID: nil, title: "ledger")

        #expect(window.windowTitle(hostName: "Studio Mac") == "ledger · Studio Mac")
        #expect(window.windowTitle(hostName: nil) == "ledger")
        #expect(window.windowTitle(hostName: "") == "ledger")
    }

    @Test("視窗不在前景時自訂控制調暗,在前景時不變")
    func inactiveWindowDimsCustomControls() {
        #expect(WindowActivity.opacity(appearsActive: true) == 1)
        #expect(WindowActivity.opacity(appearsActive: false) < 1)
        #expect(WindowActivity.opacity(appearsActive: false) > 0.3)
    }

    @Test("TabView 的選取一律落在可見的 tab")
    func tabSelectionStaysVisible() {
        #expect(TopLevelTab.visibleSelection(.files, visible: TopLevelTab.allCases) == .files)
        #expect(TopLevelTab.visibleSelection(.traffic, visible: [.chats, .files]) == .chats)
        #expect(TopLevelTab.visibleSelection(.traffic, visible: []) == .chats)
    }
}
