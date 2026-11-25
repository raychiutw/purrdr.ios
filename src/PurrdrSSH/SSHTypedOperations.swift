import Foundation
import PurrdrCore

/// SSH 的型別化主機操作(ADR-0015):把操作換成 herdr 的 NDJSON 請求與主機腳本(`HerdrWire`)，
/// 再由 `HerdrWireClient`／`TranscriptWireReader` 解析成領域型別。HTTPS 直接對應主機服務訊息，不經這裡。
extension SSHHostConnection: HerdrWire {
    private var herdrWire: HerdrWireClient { HerdrWireClient(wire: self) }

    private var transcripts: TranscriptWireReader {
        TranscriptWireReader(wire: self, windowChunkBytes: windowChunkBytes, marker: previewMarker)
    }

    public func checksSendExpectations() async -> Bool { false }

    public func readSnapshot() async throws -> HostSnapshot { try await herdrWire.snapshot() }

    public func sendKeys(paneID: String, keys: [String], expecting: SendExpectation) async throws {
        try await herdrWire.sendKeys(paneID: paneID, keys: keys, expecting: expecting)
    }

    public func sendText(paneID: String, text: String, expecting: SendExpectation) async throws {
        try await herdrWire.sendText(paneID: paneID, text: text, expecting: expecting)
    }

    public func readPaneScreen(paneID: String, lines: Int, format: PaneReadFormat) async throws -> String {
        try await herdrWire.readPane(paneID: paneID, lines: lines, format: format)
    }

    public func herdrVersion() async throws -> String { try await herdrWire.ping() }

    public func listIntegrations() async throws -> [AgentIntegration] { try await herdrWire.integrations() }

    public func reportPresence(paneID: String, model: String?, seq: UInt64) async throws {
        try await herdrWire.reportPresence(paneID: paneID, model: model, seq: seq)
    }

    public func renameWorkspace(_ workspaceID: String, to label: String) async throws {
        try await herdrWire.renameWorkspace(workspaceID, to: label)
    }

    public func renameTab(_ tabID: String, to label: String) async throws { try await herdrWire.renameTab(tabID, to: label) }

    public func closeTab(_ tabID: String) async throws { try await herdrWire.closeTab(tabID) }

    public func closeWorkspace(_ workspaceID: String) async throws { try await herdrWire.closeWorkspace(workspaceID) }

    public func createWorktree(from workspaceID: String, branch: String) async throws -> CreatedWorkspace {
        try await herdrWire.createWorktree(from: workspaceID, branch: branch)
    }

    public func createWorkspace(cwd: String, label: String?) async throws -> NewWorkspace {
        try await herdrWire.createWorkspace(cwd: cwd, label: label)
    }

    public func createTab(in workspaceID: String, label: String?) async throws -> CreatedTab {
        try await herdrWire.createTab(in: workspaceID, label: label)
    }

    public func startAgent(_ request: AgentStartRequest) async throws -> Bool { try await herdrWire.startAgent(request) }

    public func agentLaunchState(target: String) async throws -> AgentLaunchState { try await herdrWire.agentLaunchState(target: target) }

    public func listSessions(cwd: String, agent: String) async throws -> [ResumableSession] {
        try await herdrWire.listSessions(cwd: cwd, agent: agent)
    }

    public func sendPrompt(target: String, text: String, wait: Duration?, expecting: SendExpectation) async throws -> PromptReply {
        try await herdrWire.prompt(target: target, text: text, wait: wait, expecting: expecting)
    }

    public func waitForAgent(target: String, until: [AgentStatus], timeout: Duration) async throws -> Bool {
        try await herdrWire.waitForAgent(target: target, until: until, timeout: timeout)
    }

    public func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, any Error> {
        try await herdrWire.subscribe(subscriptions)
    }

    // MARK: - 對話紀錄

    public func locateTranscript(_ location: TranscriptLocation) async throws -> TranscriptFile { try await transcripts.locate(location) }

    public func readTranscriptWindow(path: String, end: Int, lines: Int, maxBytes: Int) async throws -> TranscriptChunk {
        try await transcripts.window(path: path, endingAt: end, lines: lines, maxBytes: maxBytes > 0 ? maxBytes : nil)
    }

    public func readTranscriptTail(path: String, from cursor: Int, limit: Int, catchUp: Bool) async throws -> TranscriptTailRead {
        try await transcripts.tail(path: path, from: cursor, limit: limit, catchUp: catchUp)
    }

    /// 列表預覽:一次往返讀所有聊天的檔尾,分隔標記用注入的產生器。
    public func readTranscriptPreviews(_ requests: [PreviewRequest]) async throws -> [String: TranscriptPreviewBody] {
        try await transcripts.previews(requests)
    }

    public func locateSubagent(sessionFolder: String, callID: String) async throws -> String {
        try await transcripts.locateSubagent(sessionFolder: sessionFolder, callID: callID)
    }

    public func readWorkflow(sessionFolder: String, runID: String, knownChecksum: String?) async throws -> WorkflowRead {
        try await transcripts.workflow(sessionFolder: sessionFolder, runID: runID, knownChecksum: knownChecksum)
    }

    public func readDelegationLines(path: String, callID: String, agentID: String, knownChecksum: String?) async throws -> DelegationRead {
        try await transcripts.delegationLines(path: path, callID: callID, agentID: agentID, knownChecksum: knownChecksum)
    }
}
