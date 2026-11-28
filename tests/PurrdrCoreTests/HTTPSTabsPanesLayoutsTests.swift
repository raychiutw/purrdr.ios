import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// 主機服務 0.17.0 的 `agents.list` 帶 `tabs`、`panes`、`layouts`(#729):HTTPS 主機的快照要和 SSH 主機一樣完整。
@Suite("HTTPS 主機的 Tab、Pane 與版面")
struct HTTPSTabsPanesLayoutsTests {
    private static func snapshot(_ reply: FakeHostService.AgentsReply) async throws -> HostSnapshot {
        var settings = FakeHostService.Settings()
        settings.agentsReply = reply
        let service = try await FakeHostService.start(settings)
        defer { Task { await service.stop() } }
        let connection = HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9")
        return try await HerdrClient(connection: connection).snapshot()
    }

    @Test("Tab 帶名稱與順序;沒命名的 Tab 是 herdr 給的順序號")
    func tabsCarryLabels() async throws {
        let snapshot = try await Self.snapshot(.example)

        #expect(snapshot.tabs == [
            Tab(id: "w1:t6", workspaceID: "w1", number: 1, label: "purrdr.ios"),
            Tab(id: "w1:tA", workspaceID: "w1", number: 2, label: "2"),
            Tab(id: "w2:t1", workspaceID: "w2", number: 1, label: "scratch"),
        ])
        #expect(snapshot.workspaces.map(\.number) == [1, 2])
    }

    @Test("Pane 含純終端機;Agent 以外的 Pane 沒有 agentKind,也不在 agents 裡")
    func panesIncludeTerminals() async throws {
        let snapshot = try await Self.snapshot(.example)

        #expect(snapshot.panes.map(\.id) == ["w1:p6", "w1:p7", "w2:p1"])
        #expect(snapshot.panes.first?.agentKind == "claude")
        #expect(snapshot.panes.first?.terminalTitle == "整理植物照片的標籤")
        // 範例的 agents[] 還留著 w2:p1(沒有 agent、狀態 unknown);契約說純終端機不在 agents[],以 w1:p7 為準。
        #expect(snapshot.terminalPanes.map(\.id) == ["w1:p7"])
        #expect(snapshot.terminalPanes.first?.cwd == "/Users/demo/Projects/garden-journal")
        // 同一個 Tab 的 Pane 與 Agent 靠 tabID 對得上(列表依它合成一列)。
        #expect(snapshot.agents.first?.tabID == "w1:t6")
        #expect(snapshot.panes.filter { $0.tabID == "w1:t6" }.count == 2)
    }

    @Test("版面圖:Pane 的矩形、聚焦與放大")
    func layouts() async throws {
        let snapshot = try await Self.snapshot(.example)

        let layout = try #require(snapshot.layouts?.first)
        #expect(layout.tabID == "w1:t6")
        #expect(layout.zoomed == false)
        #expect(layout.focusedPaneID == "w1:p7")
        #expect(layout.panes == [
            TabLayout.PaneRect(paneID: "w1:p6", rect: GridRect(x: 0, y: 0, width: 48, height: 40)),
            TabLayout.PaneRect(paneID: "w1:p7", rect: GridRect(x: 48, y: 0, width: 72, height: 40)),
        ])
        #expect(snapshot.layouts?.count == 2)
    }

    @Test("舊版主機服務(沒有 tabs、panes、layouts):照舊只有 Agent,版面是 nil(不是「真的沒有」)")
    func olderHostService() async throws {
        let snapshot = try await Self.snapshot(.withoutTabs)

        #expect(snapshot.agents.map(\.paneID) == ["w1:p6", "w2:p1"])
        #expect(snapshot.tabs.isEmpty)
        #expect(snapshot.panes.isEmpty)
        #expect(snapshot.layouts == nil)
    }

    @Test("Tab 版面功能的門檻是主機服務 0.17.0")
    func featureGate() {
        #expect(HostServiceFeature.agentsListLayout.minimumVersion == HostServiceVersion(0, 17, 0))
    }
}
