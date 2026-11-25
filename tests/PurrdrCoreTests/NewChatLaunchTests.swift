import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 開始新對話的主機互動(行為規格 F3.2):解析資料夾 → `workspace.create` → 在 root pane `agent.start`。
///
/// `workspace.create`、`agent.start` 會改動主機，不從真實主機錄製;回應依 `herdr api schema --json`(0.9.5)手寫:
/// `workspace_created` 有 workspace、tab、root_pane;`agent_started` 有 agent、argv。錯誤 envelope 的碼取自 behavior spec。
@Suite("開始新對話")
struct NewChatLaunchTests {
    static let bridge = HerdrCommand.bridge()

    static func workspaceCreated(_ workspace: String = "w4") -> FakeReply {
        let line = #"""
        {"id":"purrdr:workspace.create","result":{"type":"workspace_created",\#
        "workspace":{"workspace_id":"\#(workspace)","number":4,"label":"ledger","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"\#(workspace):t1","agent_status":"unknown"},\#
        "tab":{"tab_id":"\#(workspace):t1","workspace_id":"\#(workspace)","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},\#
        "root_pane":{"pane_id":"\#(workspace):p1","terminal_id":"term_0009","workspace_id":"\#(workspace)","tab_id":"\#(workspace):t1","focused":false,"agent_status":"unknown","revision":0}}}
        """#
        return FakeReply(stdout: Data(line.utf8) + [0x0A], trigger: .afterStdinLine)
    }

    static func agentStarted(kind: String = "claude", pane: String = "w4:p1") -> FakeReply {
        let line = #"""
        {"id":"purrdr:agent.start","result":{"type":"agent_started","agent":{"pane_id":"\#(pane)","workspace_id":"w4","kind":"\#(kind)","status":"idle"},"argv":["\#(kind)"]}}
        """#
        return FakeReply(stdout: Data(line.utf8) + [0x0A], trigger: .afterStdinLine)
    }

    static func error(_ method: String, code: String, message: String = "message") -> FakeReply {
        let line = #"{"id":"purrdr:\#(method)","error":{"code":"\#(code)","message":"\#(message)"}}"#
        return FakeReply(stdout: Data(line.utf8) + [0x0A], trigger: .afterStdinLine)
    }

    static func folder(_ path: String, resolvesTo absolute: String) -> (String, FakeReply) {
        (NewChatFolders.command(for: path), FakeReply(stdout: NewChatFolders.output(path: absolute, folders: [])))
    }

    static func createLine(cwd: String, label: String? = nil) -> String {
        let labelPart = label.map { #","label":"\#($0)""# } ?? ""
        return #"{"id":"purrdr:workspace.create","method":"workspace.create","params":{"cwd":"\#(cwd)","focus":false\#(labelPart)}}"# + "\n"
    }

    static func launcher(_ host: FakeHost, sleeper: RecordingSleeper = RecordingSleeper(fires: { $0 < .seconds(1) })) -> NewChatLauncher {
        NewChatLauncher(client: HerdrClient(channel: host, sleep: sleeper.sleep), folders: NewChatFolders(channel: host), sleep: sleeper.sleep)
    }

    @Test("預設權限模式沿用 agent 自己的設定：不帶 --permission-mode(不會預設成完全存取)")
    func defaultPermissionModeKeepsAgentSettings() async throws {
        let request = NewChatRequest(folder: "~/ledger", agent: .claude)
        #expect(request.permissionMode == .agentDefault)

        let host = FakeHost()
        let (command, reply) = Self.folder("~/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(command, reply: reply)
        await host.expect(Self.bridge, reply: Self.workspaceCreated())
        await host.expect(Self.bridge, reply: Self.agentStarted())

        let created = try await Self.launcher(host).start(request)

        #expect(created == NewChatStarted(workspace: CreatedWorkspace(workspaceID: "w4", rootPaneID: "w4:p1"), sentMessage: false))
        let executions = await host.executions
        #expect(executions.map(\.command) == [command, Self.bridge, Self.bridge])
        // 先解析資料夾(herdr 對不存在的資料夾會默默改用家目錄),以絕對路徑建立;focus:false 不搶桌機焦點。
        #expect(executions[1].stdinText == Self.createLine(cwd: "/Users/demo/ledger"))
        // agent 名稱是資料夾名的 slug;herdr 等 60 秒;沒有 args。
        #expect(executions[2].stdinText ==
            #"{"id":"purrdr:agent.start","method":"agent.start","params":{"kind":"claude","name":"ledger","pane_id":"w4:p1","timeout_ms":60000}}"# + "\n")
        #expect(executions.allSatisfy { !$0.stdinText.contains("bypassPermissions") && !$0.stdinText.contains("permission-mode") })
    }

    @Test("填了 tab 名稱:workspace 建好後對新 tab 送 tab.rename,之後才啟動 agent;沒填時不送")
    func tabLabelRenamesNewTab() async throws {
        let host = FakeHost()
        let (command, reply) = Self.folder("/Users/demo/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(command, reply: reply)
        await host.expect(Self.bridge, reply: Self.workspaceCreated())
        await host.expect(Self.bridge, reply: FakeReply(
            stdout: Data(#"{"id":"purrdr:tab.rename","result":{"type":"ok"}}"#.utf8) + [0x0A], trigger: .afterStdinLine))
        await host.expect(Self.bridge, reply: Self.agentStarted())

        _ = try await Self.launcher(host).start(
            NewChatRequest(folder: "/Users/demo/ledger", label: "Tax", tabLabel: "Draft", agent: .claude))

        let executions = await host.executions
        #expect(executions.map(\.command) == [command, Self.bridge, Self.bridge, Self.bridge])
        #expect(executions[1].stdinText == Self.createLine(cwd: "/Users/demo/ledger", label: "Tax"))
        #expect(executions[2].stdinText == #"{"id":"purrdr:tab.rename","method":"tab.rename","params":{"label":"Draft","tab_id":"w4:t1"}}"# + "\n")
    }

    @Test("選了權限模式：Claude 在 args 帶 --permission-mode;名稱用自訂名稱的 slug,label 照原樣")
    func explicitPermissionModeForClaude() async throws {
        let host = FakeHost()
        let (command, reply) = Self.folder("/Users/demo/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(command, reply: reply)
        await host.expect(Self.bridge, reply: Self.workspaceCreated())
        await host.expect(Self.bridge, reply: Self.agentStarted())

        _ = try await Self.launcher(host).start(
            NewChatRequest(folder: "/Users/demo/ledger", label: "Tax Report 2026", agent: .claude, permissionMode: .acceptEdits))

        let executions = await host.executions
        #expect(executions[1].stdinText == Self.createLine(cwd: "/Users/demo/ledger", label: "Tax Report 2026"))
        #expect(executions[2].stdinText ==
            #"{"id":"purrdr:agent.start","method":"agent.start","params":{"args":["--permission-mode","acceptEdits"],"kind":"claude","name":"tax-report-2026","pane_id":"w4:p1","timeout_ms":60000}}"# + "\n")
    }

    /// #400:herdr 的 Codex 整合與 Codex 共用 daemon 不相容(herdr#4649),Purrdr 啟動的 Codex 帶 `--no-daemon` 才回報得出 session。
    @Test("Codex 新聊天帶 --no-daemon;其他種類不帶")
    func codexStartsWithoutDaemon() {
        #expect(NewChatRequest(folder: "~/x", agent: .codex).agentArguments == ["--no-daemon"])
        #expect(NewChatRequest(folder: "~/x", agent: .claude).agentArguments == [])
        #expect(NewChatRequest(folder: "~/x", agent: .agy).agentArguments == [])
    }

    /// #446:Antigravity 新聊天 `--kind agy`;恢復用啟動旗標 `--conversation <id>`、接續最近一次用 `-c`(agy 1.5.14 的 `--help`)。
    /// herdr 本身沒有 resume 參數,所以旗標放在 args、不帶主機服務的 `resume_session`。
    @Test("Antigravity:新聊天 kind 是 agy、不帶 args;恢復帶 --conversation <id>;接續帶 -c")
    func antigravityNewChatAndResume() async throws {
        #expect(NewChatRequest(folder: "~/x", agent: .agy).agentArguments == [])
        #expect(NewChatRequest(folder: "~/x", agent: .agy, resumeSession: "00000000-0000-4000-8000-000000000000").agentArguments
            == ["--conversation", "00000000-0000-4000-8000-000000000000"])
        #expect(NewChatRequest(folder: "~/x", agent: .agy, continuesLastSession: true).agentArguments == ["-c"])
        // 沒有旗標的種類不會被塞旗標。
        #expect(NewChatRequest(folder: "~/x", agent: .claude, continuesLastSession: true).agentArguments == [])
        #expect(NewChatRequest(folder: "~/x", agent: .codex, resumeSession: "abc").agentArguments == ["--no-daemon"])

        let host = FakeHost()
        let (command, reply) = Self.folder("/Users/demo/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(command, reply: reply)
        await host.expect(Self.bridge, reply: Self.workspaceCreated())
        await host.expect(Self.bridge, reply: Self.agentStarted(kind: "agy"))

        _ = try await Self.launcher(host).start(NewChatRequest(
            folder: "/Users/demo/ledger", agent: .agy, resumeSession: "00000000-0000-4000-8000-000000000000"))

        #expect(await host.executions[2].stdinText ==
            #"{"id":"purrdr:agent.start","method":"agent.start","params":{"args":["--conversation","00000000-0000-4000-8000-000000000000"],"kind":"agy","name":"ledger","pane_id":"w4:p1","timeout_ms":60000}}"# + "\n")
    }

    @Test("權限模式只給 Claude:Codex 只帶 --no-daemon、不帶權限模式,kind 用 herdr 的名稱")
    func permissionModeOnlyForClaude() async throws {
        let host = FakeHost()
        let (command, reply) = Self.folder("~/notes", resolvesTo: "/Users/demo/notes")
        await host.expect(command, reply: reply)
        await host.expect(Self.bridge, reply: Self.workspaceCreated())
        await host.expect(Self.bridge, reply: Self.agentStarted(kind: "codex"))

        _ = try await Self.launcher(host).start(NewChatRequest(folder: "~/notes", agent: .codex, permissionMode: .bypassPermissions))

        #expect(await host.executions[2].stdinText ==
            #"{"id":"purrdr:agent.start","method":"agent.start","params":{"args":["--no-daemon"],"kind":"codex","name":"notes","pane_id":"w4:p1","timeout_ms":60000}}"# + "\n")
    }

    @Test("資料夾不存在：不建立 workspace")
    func missingFolderCreatesNothing() async throws {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/nope"), reply: FakeReply(exitCode: 66))

        await #expect(throws: NewChatFolderError.notFound("~/nope")) {
            try await Self.launcher(host).start(NewChatRequest(folder: "~/nope", agent: .claude))
        }
        #expect(await host.executions.count == 1)
    }

    @Test("agent_pane_busy(shell 還沒到提示字元)每 750ms 重試，最多 4 次;agent_not_ready 視為成功")
    func retriesBusyPaneThenAcceptsNotReady() async throws {
        let host = FakeHost()
        let sleeper = RecordingSleeper(fires: { $0 < .seconds(1) })
        let (command, reply) = Self.folder("~/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(command, reply: reply)
        await host.expect(Self.bridge, reply: Self.workspaceCreated())
        for _ in 0..<4 { await host.expect(Self.bridge, reply: Self.error("agent.start", code: "agent_pane_busy")) }
        await host.expect(Self.bridge, reply: Self.error("agent.start", code: "agent_not_ready"))

        let created = try await Self.launcher(host, sleeper: sleeper).start(NewChatRequest(folder: "~/ledger", agent: .claude))

        #expect(created.workspace.rootPaneID == "w4:p1")
        #expect(await host.executions.count == 7)
        #expect(await sleeper.requested.filter { $0 == .milliseconds(750) }.count == 4)
        // 我方期限比 herdr 的等待多 60 秒，絕不比 herdr 先放棄。
        #expect(await sleeper.requested.contains(.seconds(120)))
    }

    /// 實測 herdr 0.9.5(資料夾還沒被 Claude 信任時):`agent.start` 立刻成功但 `launch_pending: true`,
    /// 這時 `agent.prompt` 回 `agent_not_ready`「agent w2:p1 is not an active named agent」。
    static func agentStartedPending(pane: String = "w4:p1") -> FakeReply {
        let line = #"""
        {"id":"purrdr:agent.start","result":{"type":"agent_started","agent":{"pane_id":"\#(pane)","workspace_id":"w4","name":"ledger","agent_status":"unknown","launch_pending":true},"argv":["claude"]}}
        """#
        return FakeReply(stdout: Data(line.utf8) + [0x0A], trigger: .afterStdinLine)
    }

    /// 實測 herdr 0.9.5:`agent.get` 的 `result.agent` 帶 `agent_status`、`launch_pending`、`interactive_ready`。
    static func agentGet(status: String, launchPending: Bool?, ready: Bool?, pane: String = "w4:p1") -> FakeReply {
        let pending = launchPending.map { #","launch_pending":\#($0)"# } ?? ""
        let interactive = ready.map { #","interactive_ready":\#($0)"# } ?? ""
        let line = #"""
        {"id":"purrdr:agent.get","result":{"type":"agent_info","agent":{"pane_id":"\#(pane)","workspace_id":"w4","name":"ledger","agent_status":"\#(status)"\#(pending)\#(interactive)}}}
        """#
        return FakeReply(stdout: Data(line.utf8) + [0x0A], trigger: .afterStdinLine)
    }

    static func startedWithPending(_ host: FakeHost) async {
        let (command, reply) = folder("~/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(command, reply: reply)
        await host.expect(bridge, reply: workspaceCreated())
        await host.expect(bridge, reply: agentStartedPending())
    }

    @Test("agent.start 回 launch_pending:以 agent.get 每 500ms 輪詢，就緒後才送第一則訊息")
    func launchPendingPollsThenPrompts() async throws {
        let host = FakeHost()
        let sleeper = RecordingSleeper(fires: { $0 < .seconds(1) })
        await Self.startedWithPending(host)
        await host.expect(Self.bridge, reply: Self.agentGet(status: "unknown", launchPending: true, ready: false))
        await host.expect(Self.bridge, reply: Self.agentGet(status: "idle", launchPending: nil, ready: true))
        await host.expect(Self.bridge, reply: PromptReplies.prompted())

        let started = try await Self.launcher(host, sleeper: sleeper).start(NewChatRequest(folder: "~/ledger", agent: .claude, message: "Hi"))

        #expect(started == NewChatStarted(workspace: CreatedWorkspace(workspaceID: "w4", rootPaneID: "w4:p1"), sentMessage: true))
        let stdin = await host.executions.map(\.stdinText)
        #expect(stdin.filter { $0.contains("agent.get") }.count == 2)
        #expect(stdin.filter { $0.contains(#""method":"agent.get","params":{"target":"w4:p1"}"#) }.count == 2)
        #expect(stdin.last?.contains("agent.prompt") == true)
        #expect(await sleeper.requested.filter { $0 == .milliseconds(500) }.count == 2)
    }

    @Test("launch_pending 消失(沒有 interactive_ready 欄位)也算就緒")
    func launchPendingGoneIsReady() async throws {
        let host = FakeHost()
        await Self.startedWithPending(host)
        await host.expect(Self.bridge, reply: Self.agentGet(status: "idle", launchPending: nil, ready: nil))
        await host.expect(Self.bridge, reply: PromptReplies.prompted())

        let started = try await Self.launcher(host).start(NewChatRequest(folder: "~/ledger", agent: .claude, message: "Hi"))

        #expect(started.sentMessage)
    }

    @Test("輪詢時 agent 停在 blocked(例如資料夾信任):不送、不丟錯誤，訊息留給聊天輸入框")
    func launchPendingBlockedDoesNotPrompt() async throws {
        let host = FakeHost()
        await Self.startedWithPending(host)
        await host.expect(Self.bridge, reply: Self.agentGet(status: "blocked", launchPending: true, ready: false))

        let started = try await Self.launcher(host).start(NewChatRequest(folder: "~/ledger", agent: .claude, message: "Hi"))

        #expect(started == NewChatStarted(workspace: CreatedWorkspace(workspaceID: "w4", rootPaneID: "w4:p1"), sentMessage: false))
        #expect(await host.executions.allSatisfy { !$0.stdinText.contains("agent.prompt") })
    }

    @Test("輪詢約 20 秒仍 launch_pending:視為未就緒，不送、不丟錯誤")
    func launchPendingTimesOut() async throws {
        let host = FakeHost()
        let sleeper = RecordingSleeper(fires: { $0 < .seconds(1) })
        await Self.startedWithPending(host)
        for _ in 0..<40 { await host.expect(Self.bridge, reply: Self.agentGet(status: "unknown", launchPending: true, ready: false)) }

        let started = try await Self.launcher(host, sleeper: sleeper).start(NewChatRequest(folder: "~/ledger", agent: .claude, message: "Hi"))

        #expect(started.sentMessage == false)
        let stdin = await host.executions.map(\.stdinText)
        #expect(stdin.filter { $0.contains("agent.get") }.count == 40)
        #expect(stdin.allSatisfy { !$0.contains("agent.prompt") })
        #expect(await sleeper.requested.filter { $0 == .milliseconds(500) }.count == 40)
    }

    @Test("輪詢時 agent.get 的錯誤:agent 已經啟動,不當成啟動失敗(不丟錯誤、訊息留輸入框),重試也不多建 Workspace")
    func pollingErrorsDoNotFailTheStart() async throws {
        let host = FakeHost()
        let launcher = Self.launcher(host)
        await Self.startedWithPending(host)
        await host.expect(Self.bridge, reply: Self.error("agent.get", code: "agent_not_found"))

        let started = try await launcher.start(NewChatRequest(folder: "~/ledger", agent: .claude, message: "Hi"))

        #expect(started == NewChatStarted(workspace: CreatedWorkspace(workspaceID: "w4", rootPaneID: "w4:p1"), sentMessage: false))
        #expect(await host.executions.allSatisfy { !$0.stdinText.contains("agent.prompt") })
        #expect(await host.executions.filter { $0.stdinText.contains("workspace.create") }.count == 1)
    }

    @Test("agent.prompt 回 agent_blocked:不丟錯誤，訊息留給聊天輸入框")
    func promptBlockedKeepsTheMessage() async throws {
        let host = FakeHost()
        let (command, reply) = Self.folder("~/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(command, reply: reply)
        await host.expect(Self.bridge, reply: Self.workspaceCreated())
        await host.expect(Self.bridge, reply: Self.agentStarted())
        await host.expect(Self.bridge, reply: Self.error("agent.prompt", code: "agent_blocked", message: "agent is blocked"))

        let started = try await Self.launcher(host).start(NewChatRequest(folder: "~/ledger", agent: .claude, message: "Hi"))

        #expect(started.sentMessage == false)
    }

    @Test("agent.prompt 回 agent_not_ready(agent 還沒就緒):不丟錯誤，訊息留給聊天輸入框")
    func promptNotReadyKeepsTheMessage() async throws {
        let host = FakeHost()
        let (command, reply) = Self.folder("~/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(command, reply: reply)
        await host.expect(Self.bridge, reply: Self.workspaceCreated())
        await host.expect(Self.bridge, reply: Self.agentStarted())
        await host.expect(Self.bridge, reply: Self.error("agent.prompt", code: "agent_not_ready", message: "agent w4:p1 is not an active named agent"))

        let started = try await Self.launcher(host).start(NewChatRequest(folder: "~/ledger", agent: .claude, message: "Hi"))

        #expect(started == NewChatStarted(workspace: CreatedWorkspace(workspaceID: "w4", rootPaneID: "w4:p1"), sentMessage: false))
    }

    @Test("agent_pane_busy 重試 4 次仍失敗：丟出錯誤")
    func busyPaneGivesUpAfterFourRetries() async throws {
        let host = FakeHost()
        let (command, reply) = Self.folder("~/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(command, reply: reply)
        await host.expect(Self.bridge, reply: Self.workspaceCreated())
        for _ in 0..<5 { await host.expect(Self.bridge, reply: Self.error("agent.start", code: "agent_pane_busy")) }

        await #expect(throws: HerdrError.herdr(code: "agent_pane_busy", message: "message")) {
            try await Self.launcher(host).start(NewChatRequest(folder: "~/ledger", agent: .claude))
        }
        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("重試：同一個資料夾沿用上次建立的 workspace,只重跑 agent.start;換資料夾先關掉上次的 workspace")
    func retryReusesOrClosesTheCreatedWorkspace() async throws {
        let host = FakeHost()
        let launcher = Self.launcher(host)
        let (ledger, ledgerReply) = Self.folder("~/ledger", resolvesTo: "/Users/demo/ledger")
        await host.expect(ledger, reply: ledgerReply)
        await host.expect(Self.bridge, reply: Self.workspaceCreated("w4"))
        await host.expect(Self.bridge, reply: Self.error("agent.start", code: "agent_start_failed"))
        await #expect(throws: HerdrError.self) { try await launcher.start(NewChatRequest(folder: "~/ledger", agent: .claude)) }

        // 同資料夾(以解析後的絕對路徑比較):不再建立 workspace。
        await host.expect(ledger, reply: ledgerReply)
        await host.expect(Self.bridge, reply: Self.error("agent.start", code: "agent_start_failed"))
        await #expect(throws: HerdrError.self) { try await launcher.start(NewChatRequest(folder: "~/ledger", agent: .claude)) }
        #expect(await host.executions.count == 5)
        #expect(await host.executions[4].stdinText.contains(#""pane_id":"w4:p1""#))

        // 換資料夾：先關掉 w4,再建立新的。
        let (notes, notesReply) = Self.folder("~/notes", resolvesTo: "/Users/demo/notes")
        await host.expect(notes, reply: notesReply)
        await host.expect(Self.bridge, reply: FakeReply(stdout: Data(#"{"id":"purrdr:workspace.close","result":{"type":"ok"}}"#.utf8) + [0x0A], trigger: .afterStdinLine))
        await host.expect(Self.bridge, reply: Self.workspaceCreated("w5"))
        await host.expect(Self.bridge, reply: Self.agentStarted(pane: "w5:p1"))
        let created = try await launcher.start(NewChatRequest(folder: "~/notes", agent: .claude))

        #expect(created == NewChatStarted(workspace: CreatedWorkspace(workspaceID: "w5", rootPaneID: "w5:p1"), sentMessage: false))
        let executions = await host.executions
        #expect(executions[6].stdinText == #"{"id":"purrdr:workspace.close","method":"workspace.close","params":{"workspace_id":"w4"}}"# + "\n")
        #expect(executions[7].stdinText == Self.createLine(cwd: "/Users/demo/notes"))
    }

    @Test("agent 名稱:NFKD 去掉組合符號、小寫、非英數變 -、最長 32 字(herdr 的規則);空的用 chat")
    func agentNameSlug() {
        #expect(NewChatRequest.agentName(for: "Café Ledger!") == "cafe-ledger")
        #expect(NewChatRequest.agentName(for: "  --Weather__App--  ") == "weather-app")
        #expect(NewChatRequest.agentName(for: "記帳") == "chat")
        #expect(NewChatRequest.agentName(for: String(repeating: "a", count: 50)) == String(repeating: "a", count: 32))
        #expect(NewChatRequest.agentName(for: String(repeating: "a", count: 31) + " b") == String(repeating: "a", count: 31))
    }

    @Test("agent 名稱一律符合 herdr 的規則:小寫字母開頭、只有小寫英數與 - _、1 到 32 字(數字開頭的名稱前面加 chat-)")
    func agentNameAlwaysValid() {
        #expect(NewChatRequest.agentName(for: "2024 Plan") == "chat-2024-plan")
        for label in ["2024 Plan", "123", "Test", String(repeating: "9", count: 50), "記帳 2", "-_-", "A" + String(repeating: "b", count: 40)] {
            #expect(Self.isValidHerdrAgentName(NewChatRequest.agentName(for: label)), "\(label)")
        }
    }

    /// herdr 的錯誤訊息:agent name must start with a lowercase letter and contain only lowercase letters, digits, '-' or '_' (1-32 characters)。
    static func isValidHerdrAgentName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z][a-z0-9_-]{0,31}/) != nil
    }
}
