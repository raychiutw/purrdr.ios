import Foundation
import PurrdrCore
import PurrdrFeatures
import Testing

/// iPad 每個視窗各自的導覽狀態(#31):三欄的選取、鍵盤快捷鍵。
@MainActor
@Suite("視窗導覽")
struct WindowNavigationTests {
    private let visible = ["w2:p1", "w1:p1", "w3:p1"]

    @Test("下一個 Agent:沒選取時選第一個，之後依列表順序往下，到底停在最後一個")
    func nextAgentFollowsListOrder() {
        let model = TopNavigationModel()

        model.perform(.nextAgent, visibleAgents: visible)
        #expect(model.selectedChat == "w2:p1")
        model.perform(.nextAgent, visibleAgents: visible)
        #expect(model.selectedChat == "w1:p1")
        model.perform(.nextAgent, visibleAgents: visible)
        model.perform(.nextAgent, visibleAgents: visible)
        #expect(model.selectedChat == "w3:p1")
    }

    @Test("上一個 Agent:沒選取時選最後一個，到頂停在第一個")
    func previousAgentFollowsListOrder() {
        let model = TopNavigationModel()

        model.perform(.previousAgent, visibleAgents: visible)
        #expect(model.selectedChat == "w3:p1")
        model.perform(.previousAgent, visibleAgents: visible)
        model.perform(.previousAgent, visibleAgents: visible)
        model.perform(.previousAgent, visibleAgents: visible)
        #expect(model.selectedChat == "w2:p1")
    }

    @Test("選取的 Agent 被搜尋濾掉時，下一個從列表頂端開始")
    func nextAgentAfterSelectionFilteredOut() {
        let model = TopNavigationModel()
        model.selectedChat = "w9:p1"

        model.perform(.nextAgent, visibleAgents: visible)

        #expect(model.selectedChat == "w2:p1")
    }

    @Test("列表是空的時，切換 Agent 不改變選取")
    func switchingAgentWithEmptyList() {
        let model = TopNavigationModel()
        model.selectedChat = "w1:p1"

        model.perform(.nextAgent, visibleAgents: [])

        #expect(model.selectedChat == "w1:p1")
    }

    @Test("兩個視窗各有自己的導覽狀態：一個視窗選了 Agent、開了 sheet,另一個不受影響")
    func windowsHaveIndependentNavigation() {
        let first = TopNavigationModel()
        let second = TopNavigationModel()

        first.perform(.nextAgent, visibleAgents: visible)
        first.perform(.settings, visibleAgents: visible)

        #expect(first.selectedChat == "w2:p1")
        #expect(first.sheet == .settings)
        #expect(second.selectedChat == nil)
        #expect(second.sheet == nil)
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

        model.selectedChat = "w1:p1"
        model.perform(.openTerminal, visibleAgents: visible)
        #expect(model.openedTerminal == "w1:p1")
    }

    @Test("換選別的 Agent 時，前一個 Agent 開著的終端機收起")
    func selectingAnotherAgentClosesTerminal() {
        let model = TopNavigationModel()
        model.selectedChat = "w1:p1"
        model.perform(.openTerminal, visibleAgents: visible)

        model.perform(.nextAgent, visibleAgents: visible)

        #expect(model.selectedChat == "w3:p1")
        #expect(model.openedTerminal == nil)
    }

    // MARK: 側欄:主機與 workspace

    private static let snapshot = HostSnapshot(
        version: "0.9.5",
        workspaces: [Workspace(id: "w1", number: 1, label: "ledger"), Workspace(id: "w2", number: 2, label: "weather-app")],
        agents: [
            Agent(paneID: "w1:p1", workspaceID: "w1", kind: "claude", status: .done),
            Agent(paneID: "w1:p2", workspaceID: "w1", kind: "codex", status: .blocked),
            Agent(paneID: "w2:p1", workspaceID: "w2", kind: "claude", status: .blocked),
        ])

    private static let sections = [
        AgentSection(group: .needsYou, rows: [row("w2:p1"), row("w1:p2")]),
        AgentSection(group: .idle, rows: [row("w1:p1")]),
    ]

    private static func row(_ paneID: String) -> AgentRow {
        AgentRow(id: paneID, title: paneID, subtitle: "", preview: .status(.idle), time: nil, status: .idle)
    }

    @Test("側欄選了 workspace:列表只留那個 workspace 的 Agent,空的分組不顯示")
    func workspaceFilterKeepsOnlyItsAgents() {
        let model = TopNavigationModel()
        model.workspaceFilter = "w2"

        let sections = model.visibleSections(Self.sections, snapshot: Self.snapshot)

        #expect(sections == [AgentSection(group: .needsYou, rows: [Self.row("w2:p1")])])
    }

    @Test("側欄選「所有 workspace」時列表不變")
    func noWorkspaceFilterKeepsList() {
        let model = TopNavigationModel()

        #expect(model.visibleSections(Self.sections, snapshot: Self.snapshot) == Self.sections)
    }

    @Test("篩選的 workspace 已不在主機上(被關掉了):回到所有 workspace")
    func closedWorkspaceFilterFallsBackToAll() {
        let model = TopNavigationModel()
        model.workspaceFilter = "w9"

        #expect(model.visibleSections(Self.sections, snapshot: Self.snapshot) == Self.sections)
    }

    @Test("快捷鍵切換 Agent 依篩選後的列表順序")
    func visibleAgentsFollowFilteredOrder() {
        let model = TopNavigationModel()
        model.workspaceFilter = "w1"

        #expect(model.visibleAgents(Self.sections, snapshot: Self.snapshot) == ["w1:p2", "w1:p1"])
    }

    @Test("換主機：清掉這個視窗的 workspace 篩選、選取的聊天與終端機、版面圖卡片")
    func changingHostResetsWindowSelection() {
        let model = TopNavigationModel()
        model.workspaceFilter = "w1"
        model.selectedChat = "w1:p1"
        model.perform(.openTerminal, visibleAgents: visible)
        model.layoutCard.tap("w1")

        model.hostChanged()

        #expect(model.workspaceFilter == nil)
        #expect(model.selectedChat == nil)
        #expect(model.openedTerminal == nil)
        #expect(model.layoutCard.state == .hidden)
    }

    // MARK: 在新視窗開啟

    @Test("在新視窗開啟的 Agent 記下主機：重新啟動還原視窗時，編碼後內容不變")
    func paneWindowSurvivesRestoration() throws {
        let window = PaneWindow(kind: .chat, host: .demo, paneID: "w1:p1", sessionID: "s-1", title: "Tidy up the CSV export")

        let restored = try JSONDecoder().decode(PaneWindow.self, from: JSONEncoder().encode(window))

        #expect(restored == window)
        #expect(restored.host == .demo)
    }

    @Test("新視窗只在它的主機是選取中主機時顯示內容(其他主機的連線由選取中主機提供)")
    func paneWindowNeedsItsHostSelected() throws {
        let id = try #require(UUID(uuidString: "5EED0000-0000-4000-8000-000000000001"))
        let window = PaneWindow(kind: .terminal, host: .host(id), paneID: "w1:p1", sessionID: nil, title: "ledger")

        #expect(window.isAvailable(selection: .host(id)))
        #expect(!window.isAvailable(selection: .demo))
    }
}
