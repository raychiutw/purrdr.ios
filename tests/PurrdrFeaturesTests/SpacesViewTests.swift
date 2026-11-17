import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Spaces／Agents 兩種檢視與 workspace 群組(#40、#103)。
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

    static func groups(_ model: HostsModel) -> [WorkspaceGroup] {
        model.agentList.spacesSections.flatMap(\.items).compactMap { item in
            if case .group(let group) = item { group } else { nil }
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
        #expect(!Self.groups(model).isEmpty)
        model.agentList.mode = .agents
        #expect(model.agentList.content == .noAgentsInAgentsView)
    }

    @Test("有兩個以上 agent 的 workspace 是群組：Agent 數、各狀態數量，Agent 列依狀態(工作中在前),第三行是 Agent 種類")
    func multiAgentWorkspaceIsGroup() async throws {
        let model = await Self.model()

        let group = try #require(Self.groups(model).first { $0.workspaceID == "w1" })
        #expect(group.id == "demo/w1")
        #expect(group.label == "garden-journal")
        #expect(group.agentCount == 3)
        #expect(group.terminalCount == 0)
        #expect(group.counts == SpacesStatusCounts(working: 2, idle: 1))
        #expect(group.rows.map(\.id) == ["demo/w1:pA", "demo/w1:pB", "demo/w1:p6"])
        #expect(Self.agentRows(group).map(\.subtitle) == ["Claude Code", "Claude Code", "Claude Code"])
        // 群組裡的 agent 不再單獨出現。
        #expect(Self.chats(model).isEmpty)
    }

    @Test("只有 shell 的 workspace 也是群組：沒有 Agent、終端機數 1,終端機列的副標是程式名與資料夾")
    func shellOnlyWorkspaceListsTerminalRow() async throws {
        let model = await Self.model { response in
            // 錄製時 shell 沒有終端機標題;加上前景程式名。
            SnapshotEdit.agent("w2:p1", in: &response) { $0["terminal_title_stripped"] = "npm run dev" }
        }

        let group = try #require(Self.groups(model).first { $0.workspaceID == "w2" })
        #expect(group.agentCount == 0)
        #expect(group.terminalCount == 1)
        #expect(group.counts == SpacesStatusCounts())
        #expect(group.rows == [
            .terminal(TerminalRow(host: .demo, paneID: "w2:p1", subtitle: "npm run dev · tmp/scratch", program: "npm run dev")),
        ])
    }

    @Test("沒有程式名的終端機列副標是「Shell · 資料夾」")
    func terminalRowWithoutProgram() async throws {
        let model = await Self.model()

        let group = try #require(Self.groups(model).first { $0.workspaceID == "w2" })
        guard case .terminal(let row)? = group.rows.first else {
            Issue.record("w2 應該有終端機列")
            return
        }
        #expect(row.subtitle == "Shell · tmp/scratch")
    }

    @Test("只有一個 agent、沒有其他 pane 的 workspace 是聊天列，第三行是 workspace 名稱")
    func singleAgentWorkspaceIsChatRow() async throws {
        let model = await Self.model { response in
            SnapshotEdit.removeAgent("w1:pA", in: &response)
            SnapshotEdit.removeAgent("w1:pB", in: &response)
        }

        #expect(Self.chats(model).map(\.id) == ["demo/w1:p6"])
        #expect(Self.chats(model).first?.subtitle == "garden-journal")
        #expect(Self.groups(model).map(\.workspaceID) == ["w2"])
    }

    @Test("一個 agent 加上一個 shell pane 的 workspace 是群組：agent 列在前、終端機列在後")
    func agentWithShellIsGroup() async throws {
        let model = await Self.model { response in
            SnapshotEdit.removeAgent("w1:pA", in: &response)
            SnapshotEdit.removeAgent("w1:pB", in: &response)
            Self.addShellPane(
                ["pane_id": "w1:pZ", "workspace_id": "w1", "tab_id": "w1:t6", "cwd": "/Users/demo/Projects/garden-journal",
                 "label": "server"], to: &response)
        }

        #expect(Self.chats(model).isEmpty)
        let group = try #require(Self.groups(model).first { $0.workspaceID == "w1" })
        #expect(group.agentCount == 1)
        #expect(group.terminalCount == 1)
        #expect(group.rows.map(\.id) == ["demo/w1:p6", "demo/w1:pZ"])
    }

    static func agentRows(_ group: WorkspaceGroup) -> [AgentRow] {
        group.rows.compactMap { row in
            if case .agent(let agent) = row { agent } else { nil }
        }
    }

    @Test("Agents 檢視：每個 agent 一列，沒有群組也沒有終端機列;只有 shell 的 workspace 不出現")
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

    @Test("搜尋：命中 workspace 名稱時群組列出全部;只命中 agent 時群組只留命中的列;都不命中則沒有群組")
    func searchFiltersGroupRows() async throws {
        let model = await Self.model()

        model.agentList.query = "garden"
        let byWorkspace = try #require(Self.groups(model).first)
        #expect(byWorkspace.rows.count == 3)

        model.agentList.query = "食譜"
        let byAgent = try #require(Self.groups(model).first)
        #expect(byAgent.workspaceID == "w1")
        #expect(byAgent.rows.map(\.id) == ["demo/w1:pB"])

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
