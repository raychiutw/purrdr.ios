import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 在既有 Workspace 新增 Tab(#537):`tab.create`(herdr 0.9.5 隔離 session 實測:`workspace_id`、`focus`、`label`;
/// 不帶 `cwd` 時沿用 Workspace 的工作目錄;Workspace 不存在回 `workspace_not_found`)→ 對新 Tab 的 root pane `agent.start`。
@Suite("在既有 Workspace 新增 Tab")
struct NewChatExistingWorkspaceTests {
    static let bridge = HerdrCommand.bridge()

    /// 依實測的回應形狀(`tab_created`:tab 與 root_pane)。
    static func tabCreated(workspace: String = "w1", tab: String = "t3") -> FakeReply {
        let line = #"""
        {"id":"purrdr:tab.create","result":{"type":"tab_created",\#
        "tab":{"tab_id":"\#(workspace):\#(tab)","workspace_id":"\#(workspace)","number":3,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},\#
        "root_pane":{"pane_id":"\#(workspace):p3","terminal_id":"term_0009","workspace_id":"\#(workspace)","tab_id":"\#(workspace):\#(tab)","focused":false,"cwd":"/Users/demo/ledger","agent_status":"unknown","revision":0}}}
        """#
        return FakeReply(stdout: Data(line.utf8) + [0x0A], trigger: .afterStdinLine)
    }

    static func ok(_ method: String) -> FakeReply {
        FakeReply(stdout: Data(#"{"id":"purrdr:\#(method)","result":{"type":"ok"}}"#.utf8) + [0x0A], trigger: .afterStdinLine)
    }

    static func request(workspace: String = "w1", tabLabel: String? = nil, message: String = "") -> NewChatRequest {
        NewChatRequest(
            folder: "/Users/demo/ledger", tabLabel: tabLabel, agent: .claude, message: message, target: .existingWorkspace(id: workspace))
    }

    static func tabLine(workspace: String = "w1", label: String? = nil) -> String {
        let labelPart = label.map { #""label":"\#($0)","# } ?? ""
        return #"{"id":"purrdr:tab.create","method":"tab.create","params":{"focus":false,\#(labelPart)"workspace_id":"\#(workspace)"}}"# + "\n"
    }

    @Test("成功:不解析資料夾、不建立 Workspace;tab.create 後對新 Tab 的 root pane 啟動 agent,名稱帶 Tab 編號避免與 Workspace 裡既有的 agent 同名")
    func createsTabAndStartsAgent() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.tabCreated())
        await host.expect(Self.bridge, reply: NewChatLaunchTests.agentStarted(pane: "w1:p3"))

        let started = try await NewChatLaunchTests.launcher(host).start(Self.request())

        #expect(started == NewChatStarted(workspace: CreatedWorkspace(workspaceID: "w1", rootPaneID: "w1:p3"), sentMessage: false))
        let executions = await host.executions
        #expect(executions.map(\.command) == [Self.bridge, Self.bridge])
        #expect(executions[0].stdinText == Self.tabLine())
        #expect(executions[1].stdinText ==
            #"{"id":"purrdr:agent.start","method":"agent.start","params":{"kind":"claude","name":"ledger-t3","pane_id":"w1:p3","timeout_ms":60000}}"# + "\n")
    }

    @Test("填了 Tab 名稱:帶進 tab.create 的 label,也是 agent 名稱的來源;第一則訊息送到新 Tab 的 pane")
    func labelAndFirstMessage() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.tabCreated())
        await host.expect(Self.bridge, reply: NewChatLaunchTests.agentStarted(pane: "w1:p3"))
        await host.expect(Self.bridge, reply: FakeReply(
            stdout: Data(#"{"id":"purrdr:agent.prompt","result":{"type":"agent_prompted"}}"#.utf8) + [0x0A], trigger: .afterStdinLine))

        let started = try await NewChatLaunchTests.launcher(host).start(Self.request(tabLabel: "Draft", message: "hi"))

        #expect(started.sentMessage)
        let executions = await host.executions
        #expect(executions[0].stdinText == Self.tabLine(label: "Draft"))
        #expect(executions[1].stdinText.contains(#""name":"draft-t3""#))
        #expect(executions[2].stdinText.contains(#""target":"w1:p3""#))
    }

    @Test("Workspace 已被桌機關掉:丟 workspace_not_found,不啟動 agent、不留下待關閉的東西")
    func workspaceGone() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: NewChatLaunchTests.error("tab.create", code: "workspace_not_found", message: "workspace w1 not found"))

        await #expect(throws: HerdrError.herdr(code: "workspace_not_found", message: "workspace w1 not found")) {
            try await NewChatLaunchTests.launcher(host).start(Self.request())
        }
        #expect(await host.executions.count == 1)
    }

    @Test("重試:同一個 Workspace 沿用上次建立的 Tab,只重跑 agent.start")
    func retryReusesTheCreatedTab() async throws {
        let host = FakeHost()
        let launcher = NewChatLaunchTests.launcher(host)
        await host.expect(Self.bridge, reply: Self.tabCreated())
        await host.expect(Self.bridge, reply: NewChatLaunchTests.error("agent.start", code: "agent_start_failed"))
        await #expect(throws: HerdrError.self) { try await launcher.start(Self.request()) }

        await host.expect(Self.bridge, reply: NewChatLaunchTests.agentStarted(pane: "w1:p3"))
        let started = try await launcher.start(Self.request())

        #expect(started.workspace.rootPaneID == "w1:p3")
        let executions = await host.executions
        #expect(executions.count == 3)
        #expect(executions[2].stdinText.contains(#""pane_id":"w1:p3""#))
    }

    @Test("換目標:只關掉自己建立的 Tab(tab.close),絕不 workspace.close 使用者原本的 Workspace")
    func switchingTargetClosesOnlyTheCreatedTab() async throws {
        let host = FakeHost()
        let launcher = NewChatLaunchTests.launcher(host)
        await host.expect(Self.bridge, reply: Self.tabCreated())
        await host.expect(Self.bridge, reply: NewChatLaunchTests.error("agent.start", code: "agent_start_failed"))
        await #expect(throws: HerdrError.self) { try await launcher.start(Self.request(workspace: "w1")) }

        await host.expect(Self.bridge, reply: Self.ok("tab.close"))
        await host.expect(Self.bridge, reply: Self.tabCreated(workspace: "w2", tab: "t2"))
        await host.expect(Self.bridge, reply: NewChatLaunchTests.agentStarted(pane: "w2:p3"))
        _ = try await launcher.start(Self.request(workspace: "w2"))

        let executions = await host.executions
        #expect(executions[2].stdinText == #"{"id":"purrdr:tab.close","method":"tab.close","params":{"tab_id":"w1:t3"}}"# + "\n")
        #expect(executions[3].stdinText == Self.tabLine(workspace: "w2"))
        #expect(!executions.contains { $0.stdinText.contains("workspace.close") })
    }

    @Test("從新 Workspace 失敗改選既有 Workspace:關掉新建的 Workspace;從既有改回新的:關掉新建的 Tab")
    func switchingBetweenKinds() async throws {
        let host = FakeHost()
        let launcher = NewChatLaunchTests.launcher(host)
        let (ledger, ledgerReply) = NewChatLaunchTests.folder("~/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(ledger, reply: ledgerReply)
        await host.expect(Self.bridge, reply: NewChatLaunchTests.workspaceCreated("w4"))
        await host.expect(Self.bridge, reply: NewChatLaunchTests.error("agent.start", code: "agent_start_failed"))
        await #expect(throws: HerdrError.self) { try await launcher.start(NewChatRequest(folder: "~/ledger", agent: .claude)) }

        await host.expect(Self.bridge, reply: Self.ok("workspace.close"))
        await host.expect(Self.bridge, reply: Self.tabCreated())
        await host.expect(Self.bridge, reply: NewChatLaunchTests.error("agent.start", code: "agent_start_failed"))
        await #expect(throws: HerdrError.self) { try await launcher.start(Self.request()) }

        await host.expect(ledger, reply: ledgerReply)
        await host.expect(Self.bridge, reply: Self.ok("tab.close"))
        await host.expect(Self.bridge, reply: NewChatLaunchTests.workspaceCreated("w5"))
        await host.expect(Self.bridge, reply: NewChatLaunchTests.agentStarted(pane: "w5:p1"))
        _ = try await launcher.start(NewChatRequest(folder: "~/ledger", agent: .claude))

        let lines = await host.executions.map(\.stdinText)
        #expect(lines.contains(#"{"id":"purrdr:workspace.close","method":"workspace.close","params":{"workspace_id":"w4"}}"# + "\n"))
        #expect(lines.contains(#"{"id":"purrdr:tab.close","method":"tab.close","params":{"tab_id":"w1:t3"}}"# + "\n"))
        #expect(lines.filter { $0.contains("workspace.close") }.count == 1)
    }
}
