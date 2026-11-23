import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Spaces(#40、#501 起聊天只有 Spaces);Spaces每個「主機 · workspace」一段、列出 Tab(#275,原型 purrdr-screens 定案版)。
///
/// 錄製的 snapshot:`w1`(garden-journal)三個 Claude 各在一個 tab(`w1:t6` idle、`w1:tA`／`w1:tB` working);
/// `w2`(scratch)只有一個 shell pane `w2:p1`(`/tmp/scratch`)。
@MainActor
@Suite("Spaces 檢視")
struct SpacesViewTests {
    static func model(modify: ((inout [String: Any]) -> Void)? = nil) async -> HostsModel {
        let host = FakeHost()
        let reply: FakeReply = modify.map { .recorded("session.snapshot.ndjson", modify: $0) } ?? .recorded("session.snapshot.ndjson")
        await host.expect(HerdrCommand.bridge(), reply: reply)
        let model = HostsModel(
            store: MemoryHostStore(), demoChannel: host, makeChannel: { _, _, _ in FakeHost() })
        model.load()
        await model.agentList.load()
        return model
    }

    /// 在 snapshot 的 `panes[]` 加一個 agent 以外的 pane。
    static func addShellPane(_ pane: [String: Any], to response: inout [String: Any]) {
        var result = response["result"] as? [String: Any] ?? [:]
        var snapshot = result["snapshot"] as? [String: Any] ?? [:]
        snapshot["panes"] = (snapshot["panes"] as? [[String: Any]] ?? []) + [pane]
        result["snapshot"] = snapshot
        response["result"] = result
    }

    @Test("版面事件一律訂閱：聊天只有 Spaces，每台主機的即時更新都訂版面事件(#40、#501)")
    func layoutEventsAlwaysSubscribed() async {
        let model = await Self.model()
        #expect(model.agentList.list(for: .demo)?.subscribesToLayout == true)
    }

    @Test("只有終端機、沒有 Agent:Spaces 照常列出(#40)")
    func onlyTerminalsShowInSpaces() async throws {
        let model = await Self.model { response in
            // 改動：拿掉所有 agent(與它們的 pane),只剩 w2 的 shell。
            var result = response["result"] as? [String: Any] ?? [:]
            var snapshot = result["snapshot"] as? [String: Any] ?? [:]
            let agentPanes = Set((snapshot["agents"] as? [[String: Any]] ?? []).compactMap { $0["pane_id"] as? String })
            snapshot["agents"] = [[String: Any]]()
            snapshot["panes"] = (snapshot["panes"] as? [[String: Any]] ?? []).filter { !agentPanes.contains($0["pane_id"] as? String ?? "") }
            result["snapshot"] = snapshot
            response["result"] = result
        }

        #expect(model.agentList.content == .list, "只有終端機時 Spaces 說成沒有 Agent")
        #expect(model.agentList.spacesSections.map(\.workspaceID) == ["w2"])
    }

    @Test("每個 workspace 一段：段落是主機與 workspace 名稱，依主機上的順序;段內每個 Tab 一列")
    func sectionPerWorkspaceWithTabs() async throws {
        let model = await Self.model()

        let sections = model.agentList.spacesSections
        #expect(sections.map(\.id) == ["demo/w1", "demo/w2"])
        let garden = try #require(sections.first)
        #expect(garden.hostName == "Demo")
        #expect(garden.workspace == "garden-journal")
        #expect(garden.tabs.map(\.id) == ["demo/w1:t6", "demo/w1:tA", "demo/w1:tB"])
        #expect(sections.last?.workspace == "scratch")
    }

    @Test("Tab 名稱：人取的照原文;herdr 的預設數字名稱或沒有名稱時用 Tab 裡的內容(Agent 的聊天標題、終端機的程式名)")
    func tabTitles() async throws {
        let model = await Self.model { response in
            SnapshotEdit.tab("w1:tA", in: &response) { $0["label"] = "CSV 匯出" }
            SnapshotEdit.tab("w1:tB", in: &response) { $0["label"] = NSNull() }
        }

        let sections = model.agentList.spacesSections
        let tabs = try #require(sections.first).tabs
        // 實機回報(2026-11-20):SSH 主機的 Tab 都是 herdr 的預設名稱「1」「2」…,只顯示「Tab N」分不出來。
        #expect(tabs.map(\.title) == ["整理植物照片的標籤", "CSV 匯出", "重構食譜匯入"])
        #expect(sections.last?.tabs.map(\.title) == ["Shell"], "只有 shell 的 Tab 用程式名")
    }

    @Test("Tab 裡有多個 Agent:第一個的聊天標題加「+N」;什麼都沒有才是「Tab N」")
    func tabTitleWithSeveralAgents() async throws {
        let model = await Self.model { response in
            // 改動：w1:pB 移到 w1:t6(和 w1:p6 同一個 Tab)。
            SnapshotEdit.agent("w1:pB", in: &response) { $0["tab_id"] = "w1:t6" }
        }

        let tabs = try #require(model.agentList.spacesSections.first).tabs
        #expect(tabs.first?.title == "整理植物照片的標籤 +1")
        #expect(AgentListProjection.tabTitle(nil, contents: nil, position: 3) == "Tab 3")
    }

    @Test("Tab 列的頭像(#316):Agent 的種類與狀態;只有終端機的 Tab 是終端機頭像、沒有狀態")
    func tabAvatars() async throws {
        let model = await Self.model()

        let sections = model.agentList.spacesSections
        let garden = try #require(sections.first)
        #expect(garden.tabs[1].avatar == .agent(kind: "claude", status: .working))
        #expect(garden.tabs[2].avatar == .agent(kind: "claude", status: .working))
        #expect(sections.last?.tabs.first?.avatar == .terminal)
    }

    @Test("Tab 裡有多個 Agent(#316):頭像是第一個 Agent 的種類，狀態取最需要處理的(需要你 > 工作中 > 未讀 > 閒置)")
    func tabAvatarUsesMostUrgentStatus() async throws {
        let model = await Self.model { response in
            // 改動：w1:pA、w1:pB 移到 w1:t6(和 idle 的 w1:p6 同一個 Tab),w1:pB 改成需要你。
            SnapshotEdit.agent("w1:pA", in: &response) { $0["tab_id"] = "w1:t6" }
            SnapshotEdit.agent("w1:pB", in: &response) {
                $0["tab_id"] = "w1:t6"
                $0["agent_status"] = "blocked"
            }
        }

        let tab = try #require(model.agentList.spacesSections.first?.tabs.first)
        #expect(tab.avatar == .agent(kind: "claude", status: .blocked))
    }

    @Test("點 Tab:只有一個 pane 直接開(Agent 開對話、終端機開 Pane 終端機);有多個 pane 開那個 Tab 的版面圖")
    func tabTargets() async throws {
        let model = await Self.model { response in
            // 改動：w1:t6 再加一個 shell pane。
            Self.addShellPane(["pane_id": "w1:p7", "workspace_id": "w1", "tab_id": "w1:t6", "cwd": "/tmp"], to: &response)
        }

        let sections = model.agentList.spacesSections
        let garden = try #require(sections.first)
        #expect(garden.tabs[0].target == .layout(workspaceID: "w1", tabID: "w1:t6"))
        #expect(garden.tabs[1].target == .pane(ChatRoute(host: .demo, paneID: "w1:pA")))
        #expect(sections.last?.tabs.first?.target == .pane(ChatRoute(host: .demo, paneID: "w2:p1")))
    }

    @Test("herdr 沒有回報 Tab 的 Agent 自成一列(標題是 Agent 標題),不會從列表消失")
    func panesWithoutTabs() async throws {
        let model = await Self.model { response in
            // 改動：w1:pA 只出現在 agents、沒有 tab_id(pane 清單沒有它;pane 的 tab_id 是必填，缺了整份 snapshot 讀不了)。
            var result = response["result"] as? [String: Any] ?? [:]
            var snapshot = result["snapshot"] as? [String: Any] ?? [:]
            snapshot["panes"] = (snapshot["panes"] as? [[String: Any]] ?? []).filter { $0["pane_id"] as? String != "w1:pA" }
            snapshot["agents"] = (snapshot["agents"] as? [[String: Any]] ?? []).map { agent in
                var agent = agent
                if agent["pane_id"] as? String == "w1:pA" { agent["tab_id"] = NSNull() }
                return agent
            }
            result["snapshot"] = snapshot
            response["result"] = result
        }

        let garden = try #require(model.agentList.spacesSections.first)
        let loose = try #require(garden.tabs.first { $0.target == .pane(ChatRoute(host: .demo, paneID: "w1:pA")) })
        #expect(loose.title == "規劃天氣小工具")
    }

    @Test("同一個 ChatRoute 導覽：agent 以外的 pane 開 Pane 終端機(標題是程式名),Agent 的 pane 開對話")
    func terminalRouteOpensPaneTerminal() async throws {
        let model = await Self.model { response in
            SnapshotEdit.agent("w2:p1", in: &response) { $0["terminal_title_stripped"] = "npm run dev" }
        }

        #expect(model.agentList.terminalTitle(of: ChatRoute(host: .demo, paneID: "w2:p1")) == "npm run dev")
        #expect(model.agentList.terminalTitle(of: ChatRoute(host: .demo, paneID: "w1:p6")) == nil)
        #expect(model.agentList.terminalTitle(of: ChatRoute(host: .demo, paneID: "w9:p9")) == nil)
    }
}
