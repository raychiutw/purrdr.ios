import Foundation
import PurrdrCore

/// 每個操作都以 `error` 失敗的主機連線(仿「權杖被撤銷」「主機服務太舊」「唯讀裝置」這類整條連線被拒的情境);
/// 唯讀照 `readOnly` 回報。只需要改部分操作的測試用 `ForwardingHostConnection` 包住它再覆寫。
public struct FailingHostConnection: HostConnection {
    public let error: any Error
    public var readOnly: Bool

    public init(error: any Error, readOnly: Bool = false) {
        self.error = error
        self.readOnly = readOnly
    }

    public func isReadOnlyDevice() async throws -> Bool { readOnly }

    public func followTranscript(path: String, from cursor: Int, pace: TranscriptFollowPace) async -> AsyncThrowingStream<TranscriptFollowEvent, any Error> {
        let error = error
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }

    public func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection { throw error }
    public func disconnect() async {}

    public func readSnapshot() async throws -> HostSnapshot { throw error }
    public func sendKeys(paneID: String, keys: [String], expecting: SendExpectation) async throws { throw error }
    public func sendText(paneID: String, text: String, expecting: SendExpectation) async throws { throw error }
    public func readPaneScreen(paneID: String, lines: Int, format: PaneReadFormat) async throws -> String { throw error }
    public func locateTranscript(_ location: TranscriptLocation) async throws -> TranscriptFile { throw error }
    public func readTranscriptWindow(path: String, end: Int, lines: Int, maxBytes: Int) async throws -> TranscriptChunk { throw error }
    public func herdrVersion() async throws -> String { throw error }
    public func listIntegrations() async throws -> [AgentIntegration] { throw error }
    public func reportPresence(paneID: String, model: String?, seq: UInt64) async throws { throw error }
    public func renameWorkspace(_ workspaceID: String, to label: String) async throws { throw error }
    public func renameTab(_ tabID: String, to label: String) async throws { throw error }
    public func closeTab(_ tabID: String) async throws { throw error }
    public func closeWorkspace(_ workspaceID: String) async throws { throw error }
    public func createWorktree(from workspaceID: String, branch: String) async throws -> CreatedWorkspace { throw error }
    public func createWorkspace(cwd: String, label: String?) async throws -> NewWorkspace { throw error }
    public func createTab(in workspaceID: String, label: String?) async throws -> CreatedTab { throw error }
    public func startAgent(_ request: AgentStartRequest) async throws -> Bool { throw error }
    public func agentLaunchState(target: String) async throws -> AgentLaunchState { throw error }
    public func listSessions(cwd: String, agent: String) async throws -> [ResumableSession] { throw error }
    public func sendPrompt(target: String, text: String, wait: Duration?, expecting: SendExpectation) async throws -> PromptReply { throw error }
    public func waitForAgent(target: String, until: [AgentStatus], timeout: Duration) async throws -> Bool { throw error }
    public func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, any Error> { throw error }
    public func readTranscriptTail(path: String, from cursor: Int, limit: Int, catchUp: Bool) async throws -> TranscriptTailRead { throw error }
    public func readTranscriptPreviews(_ requests: [PreviewRequest]) async throws -> [String: TranscriptPreviewBody] { throw error }
    public func locateSubagent(sessionFolder: String, callID: String) async throws -> String { throw error }
    public func readWorkflow(sessionFolder: String, runID: String, knownChecksum: String?) async throws -> WorkflowRead { throw error }
    public func readDelegationLines(path: String, callID: String, agentID: String, knownChecksum: String?) async throws -> DelegationRead {
        throw error
    }
}
