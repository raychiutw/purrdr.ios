import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Spaces／Agents 兩種檢視與 workspace 卡片(#40、#37 故事 7–14、G1–G3)。
///
/// 錄製的 snapshot:`w1`(garden-journal)三個 Claude 各在一個 tab(`w1:t6` idle、`w1:tA`／`w1:tB` working);
/// `w2`(scratch)只有一個 shell pane `w2:p1`(`/tmp/scratch`)。
@MainActor
@Suite("Spaces 檢視")
struct SpacesViewTests {
    static func model(
        modeStore: any AgentListModeStore = InMemoryAgentListModeStore(), modify: ((inout [String: Any]) -> Void)? = nil
    ) async -> HostsModel {
        let host = FakeHost()
        let reply: FakeReply = modify.map { .recorded("session.snapshot.ndjson", modify: $0) } ?? .recorded("session.snapshot.ndjson")
        await host.expect(HerdrCommand.bridge(), reply: reply)
        let model = HostsModel(
            store: MemoryHostStore(), demoChannel: host, listMode: modeStore, makeChannel: { _, _, _ in FakeHost() })
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

    static func cards(_ model: HostsModel) -> [WorkspaceCard] {
        model.agentList.spacesSections.flatMap(\.items).compactMap { item in
            if case .card(let card) = item { card } else { nil }
        }
    }

    static func chats(_ model: HostsModel) -> [AgentRow] {
        model.agentList.spacesSections.flatMap(\.items).compactMap { item in
            if case .chat(let row) = item { row } else { nil }
        }
    }

    @Test("版面事件只在 Spaces 檢視訂閱：列表檢視決定每台主機的即時更新要不要訂閱(#40)")
    func layoutEventsFollowListMode() async {
        let model = await Self.model(modeStore: InMemoryAgentListModeStore(.agents))
        #expect(model.agentList.list(for: .demo)?.subscribesToLayout == false)

        model.agentList.mode = .spaces
        #expect(model.agentList.list(for: .demo)?.subscribesToLayout == true)

        model.agentList.mode = .agents
        #expect(model.agentList.list(for: .demo)?.subscribesToLayout == false)
    }

    @Test("只有終端機、沒有 Agent:Spaces 檢視照常列出;Agents 檢視說明沒有 Agent 並可切到 Spaces(#40)")
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

        model.agentList.mode = .spaces
        #expect(model.agentList.content == .list, "只有終端機時 Spaces 檢視說成沒有 Agent")
        #expect(!Self.cards(model).isEmpty)
        model.agentList.mode = .agents
        #expect(model.agentList.content == .noAgentsInAgentsView)
    }

    @Test("有兩個以上 agent 的 workspace 是卡片：統計行、最急迫的狀態，多個 tab 時依 tab 名稱分組")
    func multiAgentWorkspaceIsCardGroupedByTab() async throws {
        let model = await Self.model()

        let card = try #require(Self.cards(model).first { $0.workspaceID == "w1" })
        #expect(card.id == "demo/w1")
        #expect(card.label == "garden-journal")
        #expect(card.summary == "3 agents, 2 working · 3 tabs · 3 panes · demo/Projects")
        #expect(card.status == .working)
        #expect(card.groups.map(\.title) == ["1", "2", "3"])
        #expect(card.groups.map { $0.rows.map(\.id) } == [["demo/w1:p6"], ["demo/w1:pA"], ["demo/w1:pB"]])
        // 卡片裡的 agent 不再單獨出現。
        #expect(Self.chats(model).isEmpty)
    }

    @Test("只有 shell 的 workspace 也是卡片;終端機列的副標是程式名與資料夾，只有一個 tab 時不分組")
    func shellOnlyWorkspaceListsTerminalRow() async throws {
        let model = await Self.model { response in
            // 錄製時 shell 沒有終端機標題;加上前景程式名。
            SnapshotEdit.agent("w2:p1", in: &response) { $0["terminal_title_stripped"] = "npm run dev" }
        }

        let card = try #require(Self.cards(model).first { $0.workspaceID == "w2" })
        #expect(card.summary == "1 tab · 1 pane · tmp/scratch")
        #expect(card.status == .idle)
        #expect(card.groups.map(\.title) == [nil])
        #expect(card.groups.first?.rows == [
            .terminal(TerminalRow(host: .demo, paneID: "w2:p1", subtitle: "npm run dev · tmp/scratch", program: "npm run dev")),
        ])
    }

    @Test("沒有程式名的終端機列副標是「Shell · 資料夾」")
    func terminalRowWithoutProgram() async throws {
        let model = await Self.model()

        let card = try #require(Self.cards(model).first { $0.workspaceID == "w2" })
        #expect(card.groups.first?.rows.map(\.id) == ["demo/w2:p1"])
        guard case .terminal(let row)? = card.groups.first?.rows.first else {
            Issue.record("w2 應該有終端機列")
            return
        }
        #expect(row.subtitle == "Shell · tmp/scratch")
    }

    @Test("只有一個 agent、沒有其他 pane 的 workspace 是聊天列，不是卡片")
    func singleAgentWorkspaceIsChatRow() async throws {
        let model = await Self.model { response in
            SnapshotEdit.removeAgent("w1:pA", in: &response)
            SnapshotEdit.removeAgent("w1:pB", in: &response)
        }

        #expect(Self.chats(model).map(\.id) == ["demo/w1:p6"])
        #expect(Self.cards(model).map(\.workspaceID) == ["w2"])
    }

    @Test("一個 agent 加上一個 shell pane 的 workspace 是卡片：agent 列在前、終端機列在後")
    func agentWithShellIsCard() async throws {
        let model = await Self.model { response in
            SnapshotEdit.removeAgent("w1:pA", in: &response)
            SnapshotEdit.removeAgent("w1:pB", in: &response)
            Self.addShellPane(
                ["pane_id": "w1:pZ", "workspace_id": "w1", "tab_id": "w1:t6", "cwd": "/Users/demo/Projects/garden-journal",
                 "label": "server"], to: &response)
        }

        #expect(Self.chats(model).isEmpty)
        let card = try #require(Self.cards(model).first { $0.workspaceID == "w1" })
        // 只移除了 agent 與 pane,snapshot 的 tabs 仍有三個(統計來自 snapshot 的 tab 數)。
        #expect(card.summary == "1 agent · 3 tabs · 2 panes · Projects/garden-journal")
        #expect(card.status == .idle)
        #expect(card.groups.first?.rows.map(\.id) == ["demo/w1:p6", "demo/w1:pZ"])
    }

    @Test("Agents 檢視：每個 agent 一列，沒有卡片也沒有終端機列;只有 shell 的 workspace 不出現")
    func agentsViewHasNoTerminalRows() async throws {
        let model = await Self.model()
        model.agentList.mode = .agents

        let rows = model.agentList.sections.flatMap(\.rows)
        #expect(rows.map(\.id).sorted() == ["demo/w1:p6", "demo/w1:pA", "demo/w1:pB"])
        #expect(!rows.contains { $0.paneID == "w2:p1" })
    }

    @Test("檢視選擇會記住;沒存過時是 Spaces")
    func modeIsRemembered() async throws {
        let store = InMemoryAgentListModeStore()
        let first = await Self.model(modeStore: store)
        #expect(first.agentList.mode == .spaces)

        first.agentList.mode = .agents

        #expect(store.load() == .agents)
        let second = await Self.model(modeStore: store)
        #expect(second.agentList.mode == .agents)
    }

    @Test("搜尋：命中 workspace 名稱時卡片列出全部;只命中 agent 時卡片只留命中的列;都不命中則沒有卡片")
    func searchFiltersCardRows() async throws {
        let model = await Self.model()

        model.agentList.query = "garden"
        let byWorkspace = try #require(Self.cards(model).first)
        #expect(byWorkspace.groups.flatMap(\.rows).count == 3)

        model.agentList.query = "食譜"
        let byAgent = try #require(Self.cards(model).first)
        #expect(byAgent.workspaceID == "w1")
        #expect(byAgent.groups.flatMap(\.rows).map(\.id) == ["demo/w1:pB"])

        model.agentList.query = "nothing-matches"
        #expect(model.agentList.spacesSections.isEmpty)
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
