import Foundation
import PurrdrCore

/// HTTPS 的型別化主機操作(ADR-0015):直接對應主機服務協定訊息，不組成 herdr／SSH 腳本的位元組格式。
/// 錯誤是核心的 `HostServiceError`、`TranscriptReadError`。
extension HTTPSHostConnection {
    public func readSnapshot() async throws -> HostSnapshot {
        try await withDeadline(HostCommandDeadline.standard) {
            let welcome = try await self.hostServiceInfo()
            let reply = try await self.send(on: self.liveSession(), { .agentsList(.init(requestId: $0)) }, herdrMethod: "session.snapshot")
            guard case .agentsListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
            return Self.snapshot(from: result, version: welcome.herdr.version)
        }
    }

    public func sendKeys(paneID: String, keys: [String], expecting: SendExpectation) async throws {
        let expectedSession = await checkedExpectation(expecting).session
        try await withDeadline(HostCommandDeadline.standard) {
            let reply = try await self.send(
                on: self.liveSession(),
                { .paneSendKeys(.init(requestId: $0, paneId: paneID, keys: keys, expectedSession: expectedSession)) },
                herdrMethod: "pane.send_keys")
            guard case .paneSendKeysResult = reply else { throw HostServiceError.unexpectedResponse }
        }
    }

    public func sendText(paneID: String, text: String, expecting: SendExpectation) async throws {
        let expectedSession = await checkedExpectation(expecting).session
        try await withDeadline(HostCommandDeadline.standard) {
            let reply = try await self.send(
                on: self.liveSession(),
                { .paneSendText(.init(requestId: $0, paneId: paneID, text: text, expectedSession: expectedSession)) },
                herdrMethod: "pane.send_text")
            guard case .paneSendTextResult = reply else { throw HostServiceError.unexpectedResponse }
        }
    }

    public func readPaneScreen(paneID: String, lines: Int, format: PaneReadFormat) async throws -> String {
        try await requireHostService(.paneRead)
        let wireFormat: HostServiceProtocol.PaneReadFormat? = format == .ansi ? .ansi : nil
        return try await withDeadline(HostCommandDeadline.standard) {
            let reply = try await self.send(
                on: self.liveSession(),
                { .paneRead(.init(requestId: $0, paneId: paneID, source: .visible, format: wireFormat, lines: lines)) },
                herdrMethod: "pane.read")
            guard case .paneReadResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
            return result.text
        }
    }

    public func locateTranscript(_ location: TranscriptLocation) async throws -> TranscriptFile {
        guard location.isSafe else { throw TranscriptReadError.invalidReference }
        let result = try await withDeadline(HostCommandDeadline.standard) {
            try await self.locateResult(location.sessionReference, header: location.locator.readsHeader)
        }
        return try TranscriptReader.locatedFile(lines: [result.path, String(result.size)] + (result.header ?? []), for: location)
    }

    public func readTranscriptWindow(path: String, end: Int, lines: Int, maxBytes: Int) async throws -> TranscriptChunk {
        guard TranscriptReader.isValidPath(path), end >= 0, lines > 0 else { throw TranscriptReadError.invalidReference }
        let installed = maxBytes > 0 ? ((try? await hostServiceVersion()) ?? nil) : nil
        let limit: Int? = HostServiceFeature.transcriptWindowMaxBytes.isAvailable(onHostServiceVersion: installed) ? maxBytes : nil
        let result = try await withDeadline(HostCommandDeadline.maximumRead) {
            let reply = try await self.send { .transcriptWindow(.init(requestId: $0, path: path, end: end, lines: lines, maxBytes: limit)) }
            guard case .transcriptWindowResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
            return result
        }
        guard result.start <= result.end, result.end <= end else { throw TranscriptReadError.changed }
        // 回應範圍與每行原始長度加總不合 → 讀取中檔案變了，重試(與 SSH 腳本輸出的檢查相同)。
        guard result.records.reduce(0, { $0 + $1.length + 1 }) == result.end - result.start else { throw TranscriptReadError.changed }
        return TranscriptChunk(start: result.start, end: result.end, lines: result.records.map(\.text))
    }

    // MARK: - herdr 的結構與 Agent 操作(#595 第二批)

    public func herdrVersion() async throws -> String {
        try await withDeadline(HostCommandDeadline.standard) { try await self.hostServiceInfo().herdr.version }
    }

    public func listIntegrations() async throws -> [AgentIntegration] {
        throw HostServiceError.unsupported("integration.list")
    }

    public func reportPresence(paneID: String, model: String?, seq: UInt64) async throws {
        throw HostServiceError.unsupported("pane.report_metadata")
    }

    public func agentLaunchState(target: String) async throws -> AgentLaunchState {
        throw HostServiceError.unsupported("agent.get")
    }

    public func waitForAgent(target: String, until: [AgentStatus], timeout: Duration) async throws -> Bool {
        throw HostServiceError.unsupported("agent.wait")
    }

    public func renameWorkspace(_ workspaceID: String, to label: String) async throws {
        let reply = try await perform(.workspaceRename) { .workspaceRename(.init(requestId: $0, workspaceId: workspaceID, label: label)) }
        guard case .workspaceRenameResult = reply else { throw HostServiceError.unexpectedResponse }
    }

    public func renameTab(_ tabID: String, to label: String) async throws {
        let reply = try await perform(.tabRename) { .tabRename(.init(requestId: $0, tabId: tabID, label: label)) }
        guard case .tabRenameResult = reply else { throw HostServiceError.unexpectedResponse }
    }

    public func closeTab(_ tabID: String) async throws {
        let reply = try await perform(.tabClose) { .tabClose(.init(requestId: $0, tabId: tabID)) }
        guard case .tabCloseResult = reply else { throw HostServiceError.unexpectedResponse }
    }

    public func closeWorkspace(_ workspaceID: String) async throws {
        let reply = try await perform(.workspaceClose) { .workspaceClose(.init(requestId: $0, workspaceId: workspaceID)) }
        guard case .workspaceCloseResult = reply else { throw HostServiceError.unexpectedResponse }
    }

    public func createWorktree(from workspaceID: String, branch: String) async throws -> CreatedWorkspace {
        let reply = try await perform(.worktreeCreate) { .worktreeCreate(.init(requestId: $0, workspaceId: workspaceID, branch: branch)) }
        guard case .worktreeCreateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return CreatedWorkspace(workspaceID: result.workspaceId, rootPaneID: result.rootPaneId)
    }

    public func createWorkspace(cwd: String, label: String?) async throws -> NewWorkspace {
        let reply = try await perform(.workspaceCreate, deadline: HerdrClient.createDeadline) {
            .workspaceCreate(.init(requestId: $0, cwd: cwd, label: label))
        }
        guard case .workspaceCreateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        // 主機服務的結果沒有 tab id:呼叫端略過為新 tab 命名。
        return NewWorkspace(workspace: CreatedWorkspace(workspaceID: result.workspaceId, rootPaneID: result.rootPaneId), rootTabID: nil)
    }

    public func createTab(in workspaceID: String, label: String?) async throws -> CreatedTab {
        let reply = try await perform(.tabCreate, deadline: HerdrClient.createDeadline) {
            .tabCreate(.init(requestId: $0, workspaceId: workspaceID, label: label))
        }
        guard case .tabCreateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return CreatedTab(workspaceID: workspaceID, tabID: result.tabId, rootPaneID: result.rootPaneId)
    }

    public func startAgent(_ request: AgentStartRequest) async throws -> Bool {
        // 主機服務只收 Claude Code 的權限模式:其他參數在送出前丟 `unsupported`。
        let mode = try HerdrMethod.permissionMode(kind: request.kind, arguments: request.arguments, method: HerdrMethod.agentStart.rawValue)
        let timeoutMs = Self.milliseconds(request.timeout)
        let reply = try await perform(.agentStart, deadline: HerdrClient.startDeadline(timeout: request.timeout)) {
            .agentStart(.init(
                requestId: $0, paneId: request.paneID, name: request.name, kind: request.kind, permissionMode: mode,
                resumeSession: request.resumeSession, timeoutMs: timeoutMs))
        }
        guard case .agentStartResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return !result.launchPending
    }

    public func listSessions(cwd: String, agent: String) async throws -> [ResumableSession] {
        guard let kind = HostServiceProtocol.ResumableAgentKind(rawValue: agent) else {
            throw HostServiceError.unsupported(HerdrMethod.sessionsList.rawValue)
        }
        let reply = try await perform(.sessionsList) { .sessionsList(.init(requestId: $0, cwd: cwd, agentKind: kind)) }
        guard case .sessionsListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return result.sessions.map { entry in
            ResumableSession(
                id: entry.id, modified: try? Date(entry.modified, strategy: .iso8601),
                summary: entry.summary.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    public func sendPrompt(target: String, text: String, wait: Duration?, expecting: SendExpectation) async throws -> PromptReply {
        let expectedSession = await checkedExpectation(expecting).session
        let promptWait = wait.map { HostServiceProtocol.PromptWait(until: [.working, .blocked], timeoutMs: Self.milliseconds($0)) }
        let reply = try await perform(.agentPrompt, deadline: HerdrClient.promptDeadline(wait: wait)) {
            .agentPrompt(.init(requestId: $0, paneId: target, text: text, wait: promptWait, expectedSession: expectedSession))
        }
        guard case .agentPromptResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return PromptReply(writtenOnly: result.delivery == "written_to_pty")
    }

    /// 送出一個 herdr method 對應的主機服務訊息:先檢查版本門檻(送出前),再在期限內握手並送出。
    private func perform(
        _ method: HerdrMethod, deadline: Duration = HostCommandDeadline.standard,
        _ make: @escaping @Sendable (String) -> HostServiceProtocol.ClientMessage
    ) async throws -> HostServiceProtocol.ServerMessage {
        if let feature = method.requiredFeature { try await requireHostService(feature) }
        // 新增聊天／續接與關閉會用到的請求記下耗時(#689;與 SSH 的 `timedMethods` 同一組,名稱 `https.request <method>`)。
        let sink = Self.timedMethods.contains(method.rawValue) ? timingSink.current : nil
        return try await OperationTimer.measure("https.request \(method.rawValue)", sink: sink) {
            try await withDeadline(deadline) {
                _ = try await self.hostServiceInfo()
                return try await self.send(on: self.liveSession(), make, herdrMethod: method.rawValue)
            }
        }
    }

    /// 記耗時的請求:與 SSH 相同(`SSHHostConnection.timedMethods`);快照輪詢這類頻繁的讀取不記。
    static let timedMethods: Set<String> = ["workspace.create", "tab.create", "agent.start", "agent.get", "agent.prompt", "tab.close", "workspace.close"]

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - 對話紀錄的追蹤讀取、預覽、subagent、workflow、委派(#595 第二批 C)

    public func readTranscriptTail(path: String, from cursor: Int, limit: Int, catchUp: Bool) async throws -> TranscriptTailRead {
        guard TranscriptReader.isValidPath(path), cursor >= 0, limit > 0 else { throw TranscriptReadError.invalidReference }
        // 主機服務(#173 起)落後超過上限時從游標分段送出，與 SSH 的分段接著讀相同;行從推送累積的緩衝回答，不必依上限放寬期限。
        let answer: TailAnswer
        do {
            answer = try await withDeadline(HostCommandDeadline.standard) { try await self.tail(path: path, from: cursor, limit: limit) }
        } catch TranscriptReadError.replaced(let size) {
            // 主機服務回報檔案被換掉：與 SSH 的「變小」同樣是真正的斷層。
            return TranscriptTailRead(tail: .shrank(size: size), size: size)
        }
        return try TranscriptReader.interpretTail(size: answer.size, cursor: cursor, limit: limit, catchUp: catchUp) {
            (answer.records.map(\.text), answer.records.reduce(0) { $0 + $1.length + 1 })
        }
    }

    public func readTranscriptPreviews(_ requests: [PreviewRequest]) async throws -> [String: TranscriptPreviewBody] {
        try await previewBodies(requests)
    }

    public func locateSubagent(sessionFolder: String, callID: String) async throws -> String {
        let path = try await subagentPath(sessionFolder: sessionFolder, callID: callID)
        // 路徑不合規格視同找不到(與 SSH 腳本輸出經 `TranscriptReader` 檢查後的結果相同)。
        guard TranscriptReader.isValidPath(path) else { throw TranscriptReadError.absent }
        return path
    }

    public func readWorkflow(sessionFolder: String, runID: String, knownChecksum: String?) async throws -> WorkflowRead {
        try await workflow(sessionFolder: sessionFolder, runID: runID, knownChecksum: knownChecksum)
    }

    public func readDelegationLines(path: String, callID: String, agentID: String, knownChecksum: String?) async throws -> DelegationRead {
        try await delegation(path: path, callID: callID, agentID: agentID, knownChecksum: knownChecksum)
    }

    // MARK: - 輔助

    /// 主機會比對時才帶比對欄位(與 `HerdrClient` 相同)。
    private func checkedExpectation(_ expectation: SendExpectation) async -> SendExpectation {
        guard !expectation.isEmpty, await checksSendExpectations() else { return .none }
        return expectation
    }

    static func snapshot(from result: HostServiceProtocol.AgentsListResult, version: String) -> HostSnapshot {
        func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        let labels = Dictionary(result.workspaces.map { ($0.workspaceId, $0.label) }, uniquingKeysWith: { first, _ in first })
        // 主機服務沒回編號:以陣列順序(同 herdr)當編號,列表才排得出順序。
        var tabNumbers: [String: Int] = [:]
        return HostSnapshot(
            version: version,
            workspaces: result.workspaces.enumerated().map { index, workspace in
                Workspace(id: workspace.workspaceId, number: index + 1, label: nonEmpty(workspace.label))
            },
            agents: result.agents.map { agent in
                Agent(
                    paneID: agent.paneId, workspaceID: agent.workspaceId, kind: agent.agent ?? "",
                    status: AgentStatus(rawValue: agent.status.rawValue) ?? .unknown,
                    terminalTitle: nonEmpty(agent.title), workspaceLabel: nonEmpty(labels[agent.workspaceId]), cwd: nonEmpty(agent.cwd),
                    session: agent.session.map { AgentSessionReference(kind: $0.kind, value: $0.value) }, tabID: nonEmpty(agent.tabId))
            },
            // 0.17.0 起一律帶 tabs、panes、layouts;更舊的主機服務沒有,tabs、panes 留空、layouts 為 nil(與 SSH 的「沒回報」相同)。
            tabs: (result.tabs ?? []).map { tab in
                tabNumbers[tab.workspaceId, default: 0] += 1
                return Tab(id: tab.tabId, workspaceID: tab.workspaceId, number: tabNumbers[tab.workspaceId] ?? 0, label: nonEmpty(tab.label))
            },
            panes: (result.panes ?? []).map { pane in
                Pane(
                    id: pane.paneId, workspaceID: pane.workspaceId, tabID: pane.tabId, agentKind: nonEmpty(pane.agent),
                    cwd: nonEmpty(pane.cwd), terminalTitle: nonEmpty(pane.terminalTitleStripped) ?? nonEmpty(pane.terminalTitle))
            },
            layouts: result.layouts.map { layouts in
                layouts.map { layout in
                    TabLayout(
                        workspaceID: layout.workspaceId, tabID: layout.tabId, zoomed: layout.zoomed, focusedPaneID: nonEmpty(layout.focusedPaneId),
                        panes: layout.panes.map {
                            TabLayout.PaneRect(
                                paneID: $0.paneId, rect: GridRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height))
                        })
                }
            })
    }
}
