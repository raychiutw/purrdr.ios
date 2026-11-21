// 由 protocol/host-service.schema.json 產生，不要手動修改。重新產生:cd host-service && cargo run -p protocol-codegen

import Foundation

/// 主機服務協定(ADR-0010)的訊息型別。
public enum HostServiceProtocol {
    /// 協定版本(schema 的 `x-protocol-version`)。
    public static let version = 1
    /// 主機取檔的排除清單(schema 的 `x-excluded-file-locations`)。
    public static let excludedFileLocations = [".ssh", ".gnupg", ".aws", ".azure", ".config/gcloud", ".kube", ".docker", ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".config/gh", ".cargo/credentials", ".cargo/credentials.toml", ".password-store", ".local/share/keyrings", "Library/Keychains", ".codex/auth.json", ".claude/.credentials.json", ".claude.json", ".purrdr/host-service", ".purrdr/push-*", ".env", ".env.*", ".vault-token", ".terraform.d", ".m2/settings.xml", ".git/config", ".bash_history", ".zsh_history", "ConsoleHost_history.txt", "Library/Application Support/Google/Chrome", "Library/Application Support/Microsoft Edge", "Library/Application Support/BraveSoftware", "Library/Application Support/Firefox", "Library/Cookies", "Library/Safari", ".mozilla", ".config/google-chrome", ".config/chromium", ".config/microsoft-edge", ".config/BraveSoftware", "AppData/Local/Google/Chrome/User Data", "AppData/Local/Microsoft/Edge/User Data", "AppData/Local/BraveSoftware", "AppData/Roaming/Mozilla/Firefox", "AppData/Roaming/Microsoft/Credentials", "AppData/Roaming/Microsoft/Protect"]
    /// 主機取檔在工作目錄以外可放行的系統暫存目錄(schema 的 `x-temporary-file-locations`)。
    public static let temporaryFileLocations = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
    /// 暫存目錄底下的上傳資料夾名稱(schema 的 `x-upload-folder`;Unix 之後接 `-<uid>`)。
    public static let uploadFolder = "purrdr-uploads"
    /// 主機取檔的大小上限(schema 的 `x-maximum-file-size`)。
    public static let maximumFileSize = 26214400
    /// 主機取檔一次讀取最多回傳的 bytes(schema 的 `x-maximum-file-chunk`)。
    public static let maximumFileChunk = 1048576
}

extension HostServiceProtocol {
    /// app 送給主機服務的訊息，以 type 區分。標 x-write 的是寫入類操作，唯讀裝置送出時被拒絕(read_only_device)。
    public enum ClientMessage: Codable, Sendable, Equatable {
        case hello(Hello)
        case agentsList(AgentsList)
        case paneSendKeys(PaneSendKeys)
        case transcriptLocate(TranscriptLocate)
        case transcriptWindow(TranscriptWindow)
        case transcriptFollow(TranscriptFollow)
        case transcriptUnfollow(TranscriptUnfollow)
        case transcriptPreviews(TranscriptPreviews)
        case transcriptSubagent(TranscriptSubagent)
        case transcriptWorkflow(TranscriptWorkflow)
        case transcriptDelegation(TranscriptDelegation)
        case paneSendText(PaneSendText)
        case agentPrompt(AgentPrompt)
        case eventsSubscribe(EventsSubscribe)
        case eventsUnsubscribe(EventsUnsubscribe)
        case paneTerminalOpen(PaneTerminalOpen)
        case paneTerminalInput(PaneTerminalInput)
        case paneTerminalResize(PaneTerminalResize)
        case paneTerminalScroll(PaneTerminalScroll)
        case paneTerminalClose(PaneTerminalClose)
        case fileStat(FileStat)
        case fileRead(FileRead)
        case pushStatus(PushStatus)
        case pushInstall(PushInstall)
        case pushRemove(PushRemove)
        case pushUpdateMuted(PushUpdateMuted)
        case pushTest(PushTest)
        case workspaceCreate(WorkspaceCreate)
        case workspaceRename(WorkspaceRename)
        case workspaceClose(WorkspaceClose)
        case worktreeCreate(WorktreeCreate)
        case agentStart(AgentStart)
        case fileUploadStart(FileUploadStart)
        case fileUploadChunk(FileUploadChunk)
        case devicesList(DevicesList)
        case devicesRevoke(DevicesRevoke)
        case hostServiceStatus(HostServiceStatus)
        case hostServiceUpdate(HostServiceUpdate)
        case hostServiceSetAutoUpdate(HostServiceSetAutoUpdate)
        case paneRead(PaneRead)
        case sessionsList(SessionsList)
        case gitStatus(GitStatus)
        case gitDiff(GitDiff)
        case queueList(QueueList)
        case queueAdd(QueueAdd)
        case queueRemove(QueueRemove)
        case queueReorder(QueueReorder)

        private enum TypeKey: String, CodingKey {
            case type
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: TypeKey.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "hello": self = .hello(try Hello(from: decoder))
            case "agents.list": self = .agentsList(try AgentsList(from: decoder))
            case "pane.send_keys": self = .paneSendKeys(try PaneSendKeys(from: decoder))
            case "transcript.locate": self = .transcriptLocate(try TranscriptLocate(from: decoder))
            case "transcript.window": self = .transcriptWindow(try TranscriptWindow(from: decoder))
            case "transcript.follow": self = .transcriptFollow(try TranscriptFollow(from: decoder))
            case "transcript.unfollow": self = .transcriptUnfollow(try TranscriptUnfollow(from: decoder))
            case "transcript.previews": self = .transcriptPreviews(try TranscriptPreviews(from: decoder))
            case "transcript.subagent": self = .transcriptSubagent(try TranscriptSubagent(from: decoder))
            case "transcript.workflow": self = .transcriptWorkflow(try TranscriptWorkflow(from: decoder))
            case "transcript.delegation": self = .transcriptDelegation(try TranscriptDelegation(from: decoder))
            case "pane.send_text": self = .paneSendText(try PaneSendText(from: decoder))
            case "agent.prompt": self = .agentPrompt(try AgentPrompt(from: decoder))
            case "events.subscribe": self = .eventsSubscribe(try EventsSubscribe(from: decoder))
            case "events.unsubscribe": self = .eventsUnsubscribe(try EventsUnsubscribe(from: decoder))
            case "pane.terminal.open": self = .paneTerminalOpen(try PaneTerminalOpen(from: decoder))
            case "pane.terminal.input": self = .paneTerminalInput(try PaneTerminalInput(from: decoder))
            case "pane.terminal.resize": self = .paneTerminalResize(try PaneTerminalResize(from: decoder))
            case "pane.terminal.scroll": self = .paneTerminalScroll(try PaneTerminalScroll(from: decoder))
            case "pane.terminal.close": self = .paneTerminalClose(try PaneTerminalClose(from: decoder))
            case "file.stat": self = .fileStat(try FileStat(from: decoder))
            case "file.read": self = .fileRead(try FileRead(from: decoder))
            case "push.status": self = .pushStatus(try PushStatus(from: decoder))
            case "push.install": self = .pushInstall(try PushInstall(from: decoder))
            case "push.remove": self = .pushRemove(try PushRemove(from: decoder))
            case "push.update_muted": self = .pushUpdateMuted(try PushUpdateMuted(from: decoder))
            case "push.test": self = .pushTest(try PushTest(from: decoder))
            case "workspace.create": self = .workspaceCreate(try WorkspaceCreate(from: decoder))
            case "workspace.rename": self = .workspaceRename(try WorkspaceRename(from: decoder))
            case "workspace.close": self = .workspaceClose(try WorkspaceClose(from: decoder))
            case "worktree.create": self = .worktreeCreate(try WorktreeCreate(from: decoder))
            case "agent.start": self = .agentStart(try AgentStart(from: decoder))
            case "file.upload.start": self = .fileUploadStart(try FileUploadStart(from: decoder))
            case "file.upload.chunk": self = .fileUploadChunk(try FileUploadChunk(from: decoder))
            case "devices.list": self = .devicesList(try DevicesList(from: decoder))
            case "devices.revoke": self = .devicesRevoke(try DevicesRevoke(from: decoder))
            case "host_service.status": self = .hostServiceStatus(try HostServiceStatus(from: decoder))
            case "host_service.update": self = .hostServiceUpdate(try HostServiceUpdate(from: decoder))
            case "host_service.set_auto_update": self = .hostServiceSetAutoUpdate(try HostServiceSetAutoUpdate(from: decoder))
            case "pane.read": self = .paneRead(try PaneRead(from: decoder))
            case "sessions.list": self = .sessionsList(try SessionsList(from: decoder))
            case "git.status": self = .gitStatus(try GitStatus(from: decoder))
            case "git.diff": self = .gitDiff(try GitDiff(from: decoder))
            case "queue.list": self = .queueList(try QueueList(from: decoder))
            case "queue.add": self = .queueAdd(try QueueAdd(from: decoder))
            case "queue.remove": self = .queueRemove(try QueueRemove(from: decoder))
            case "queue.reorder": self = .queueReorder(try QueueReorder(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown message type \(type)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: TypeKey.self)
            switch self {
            case .hello(let message):
                try container.encode("hello", forKey: .type)
                try message.encode(to: encoder)
            case .agentsList(let message):
                try container.encode("agents.list", forKey: .type)
                try message.encode(to: encoder)
            case .paneSendKeys(let message):
                try container.encode("pane.send_keys", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptLocate(let message):
                try container.encode("transcript.locate", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptWindow(let message):
                try container.encode("transcript.window", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptFollow(let message):
                try container.encode("transcript.follow", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptUnfollow(let message):
                try container.encode("transcript.unfollow", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptPreviews(let message):
                try container.encode("transcript.previews", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptSubagent(let message):
                try container.encode("transcript.subagent", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptWorkflow(let message):
                try container.encode("transcript.workflow", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptDelegation(let message):
                try container.encode("transcript.delegation", forKey: .type)
                try message.encode(to: encoder)
            case .paneSendText(let message):
                try container.encode("pane.send_text", forKey: .type)
                try message.encode(to: encoder)
            case .agentPrompt(let message):
                try container.encode("agent.prompt", forKey: .type)
                try message.encode(to: encoder)
            case .eventsSubscribe(let message):
                try container.encode("events.subscribe", forKey: .type)
                try message.encode(to: encoder)
            case .eventsUnsubscribe(let message):
                try container.encode("events.unsubscribe", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalOpen(let message):
                try container.encode("pane.terminal.open", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalInput(let message):
                try container.encode("pane.terminal.input", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalResize(let message):
                try container.encode("pane.terminal.resize", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalScroll(let message):
                try container.encode("pane.terminal.scroll", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalClose(let message):
                try container.encode("pane.terminal.close", forKey: .type)
                try message.encode(to: encoder)
            case .fileStat(let message):
                try container.encode("file.stat", forKey: .type)
                try message.encode(to: encoder)
            case .fileRead(let message):
                try container.encode("file.read", forKey: .type)
                try message.encode(to: encoder)
            case .pushStatus(let message):
                try container.encode("push.status", forKey: .type)
                try message.encode(to: encoder)
            case .pushInstall(let message):
                try container.encode("push.install", forKey: .type)
                try message.encode(to: encoder)
            case .pushRemove(let message):
                try container.encode("push.remove", forKey: .type)
                try message.encode(to: encoder)
            case .pushUpdateMuted(let message):
                try container.encode("push.update_muted", forKey: .type)
                try message.encode(to: encoder)
            case .pushTest(let message):
                try container.encode("push.test", forKey: .type)
                try message.encode(to: encoder)
            case .workspaceCreate(let message):
                try container.encode("workspace.create", forKey: .type)
                try message.encode(to: encoder)
            case .workspaceRename(let message):
                try container.encode("workspace.rename", forKey: .type)
                try message.encode(to: encoder)
            case .workspaceClose(let message):
                try container.encode("workspace.close", forKey: .type)
                try message.encode(to: encoder)
            case .worktreeCreate(let message):
                try container.encode("worktree.create", forKey: .type)
                try message.encode(to: encoder)
            case .agentStart(let message):
                try container.encode("agent.start", forKey: .type)
                try message.encode(to: encoder)
            case .fileUploadStart(let message):
                try container.encode("file.upload.start", forKey: .type)
                try message.encode(to: encoder)
            case .fileUploadChunk(let message):
                try container.encode("file.upload.chunk", forKey: .type)
                try message.encode(to: encoder)
            case .devicesList(let message):
                try container.encode("devices.list", forKey: .type)
                try message.encode(to: encoder)
            case .devicesRevoke(let message):
                try container.encode("devices.revoke", forKey: .type)
                try message.encode(to: encoder)
            case .hostServiceStatus(let message):
                try container.encode("host_service.status", forKey: .type)
                try message.encode(to: encoder)
            case .hostServiceUpdate(let message):
                try container.encode("host_service.update", forKey: .type)
                try message.encode(to: encoder)
            case .hostServiceSetAutoUpdate(let message):
                try container.encode("host_service.set_auto_update", forKey: .type)
                try message.encode(to: encoder)
            case .paneRead(let message):
                try container.encode("pane.read", forKey: .type)
                try message.encode(to: encoder)
            case .sessionsList(let message):
                try container.encode("sessions.list", forKey: .type)
                try message.encode(to: encoder)
            case .gitStatus(let message):
                try container.encode("git.status", forKey: .type)
                try message.encode(to: encoder)
            case .gitDiff(let message):
                try container.encode("git.diff", forKey: .type)
                try message.encode(to: encoder)
            case .queueList(let message):
                try container.encode("queue.list", forKey: .type)
                try message.encode(to: encoder)
            case .queueAdd(let message):
                try container.encode("queue.add", forKey: .type)
                try message.encode(to: encoder)
            case .queueRemove(let message):
                try container.encode("queue.remove", forKey: .type)
                try message.encode(to: encoder)
            case .queueReorder(let message):
                try container.encode("queue.reorder", forKey: .type)
                try message.encode(to: encoder)
            }
        }

        /// 寫入類訊息(schema 的 `x-write`);唯讀裝置送出時被拒絕。
        public var isWrite: Bool {
            switch self {
            case .paneSendKeys, .paneSendText, .agentPrompt, .paneTerminalInput, .paneTerminalResize, .paneTerminalScroll, .pushInstall, .pushRemove, .pushUpdateMuted, .pushTest, .workspaceCreate, .workspaceRename, .workspaceClose, .worktreeCreate, .agentStart, .fileUploadStart, .fileUploadChunk, .devicesRevoke, .hostServiceUpdate, .hostServiceSetAutoUpdate, .queueAdd, .queueRemove, .queueReorder: return true
            default: return false
            }
        }
    }
}

extension HostServiceProtocol {
    /// 主機服務送給 app 的訊息，以 type 區分。
    public enum ServerMessage: Codable, Sendable, Equatable {
        case welcome(Welcome)
        case agentsListResult(AgentsListResult)
        case paneSendKeysResult(PaneSendKeysResult)
        case transcriptLocateResult(TranscriptLocateResult)
        case transcriptWindowResult(TranscriptWindowResult)
        case transcriptFollowResult(TranscriptFollowResult)
        case transcriptUpdate(TranscriptUpdate)
        case transcriptUnfollowResult(TranscriptUnfollowResult)
        case transcriptPreviewsResult(TranscriptPreviewsResult)
        case transcriptSubagentResult(TranscriptSubagentResult)
        case transcriptWorkflowResult(TranscriptWorkflowResult)
        case transcriptDelegationResult(TranscriptDelegationResult)
        case paneSendTextResult(PaneSendTextResult)
        case agentPromptResult(AgentPromptResult)
        case eventsSubscribeResult(EventsSubscribeResult)
        case subscribedEvent(SubscribedEvent)
        case eventsEnded(EventsEnded)
        case eventsUnsubscribeResult(EventsUnsubscribeResult)
        case paneTerminalOpenResult(PaneTerminalOpenResult)
        case paneTerminalFrame(PaneTerminalFrame)
        case paneTerminalClosed(PaneTerminalClosed)
        case fileStatResult(FileStatResult)
        case fileReadResult(FileReadResult)
        case pushStatusResult(PushStatusResult)
        case pushInstallResult(PushInstallResult)
        case pushRemoveResult(PushRemoveResult)
        case pushUpdateMutedResult(PushUpdateMutedResult)
        case pushTestResult(PushTestResult)
        case workspaceCreateResult(WorkspaceCreateResult)
        case workspaceRenameResult(WorkspaceRenameResult)
        case workspaceCloseResult(WorkspaceCloseResult)
        case worktreeCreateResult(WorktreeCreateResult)
        case agentStartResult(AgentStartResult)
        case fileUploadStartResult(FileUploadStartResult)
        case fileUploadChunkResult(FileUploadChunkResult)
        case devicesListResult(DevicesListResult)
        case devicesRevokeResult(DevicesRevokeResult)
        case hostServiceStatusResult(HostServiceStatusResult)
        case hostServiceUpdateResult(HostServiceUpdateResult)
        case hostServiceSetAutoUpdateResult(HostServiceSetAutoUpdateResult)
        case errorMessage(ErrorMessage)
        case paneReadResult(PaneReadResult)
        case sessionsListResult(SessionsListResult)
        case gitStatusResult(GitStatusResult)
        case gitDiffResult(GitDiffResult)
        case queueListResult(QueueListResult)
        case queueAddResult(QueueAddResult)
        case queueRemoveResult(QueueRemoveResult)
        case queueReorderResult(QueueReorderResult)
        case queueChanged(QueueChanged)

        private enum TypeKey: String, CodingKey {
            case type
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: TypeKey.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "welcome": self = .welcome(try Welcome(from: decoder))
            case "agents.list.result": self = .agentsListResult(try AgentsListResult(from: decoder))
            case "pane.send_keys.result": self = .paneSendKeysResult(try PaneSendKeysResult(from: decoder))
            case "transcript.locate.result": self = .transcriptLocateResult(try TranscriptLocateResult(from: decoder))
            case "transcript.window.result": self = .transcriptWindowResult(try TranscriptWindowResult(from: decoder))
            case "transcript.follow.result": self = .transcriptFollowResult(try TranscriptFollowResult(from: decoder))
            case "transcript.update": self = .transcriptUpdate(try TranscriptUpdate(from: decoder))
            case "transcript.unfollow.result": self = .transcriptUnfollowResult(try TranscriptUnfollowResult(from: decoder))
            case "transcript.previews.result": self = .transcriptPreviewsResult(try TranscriptPreviewsResult(from: decoder))
            case "transcript.subagent.result": self = .transcriptSubagentResult(try TranscriptSubagentResult(from: decoder))
            case "transcript.workflow.result": self = .transcriptWorkflowResult(try TranscriptWorkflowResult(from: decoder))
            case "transcript.delegation.result": self = .transcriptDelegationResult(try TranscriptDelegationResult(from: decoder))
            case "pane.send_text.result": self = .paneSendTextResult(try PaneSendTextResult(from: decoder))
            case "agent.prompt.result": self = .agentPromptResult(try AgentPromptResult(from: decoder))
            case "events.subscribe.result": self = .eventsSubscribeResult(try EventsSubscribeResult(from: decoder))
            case "events.event": self = .subscribedEvent(try SubscribedEvent(from: decoder))
            case "events.ended": self = .eventsEnded(try EventsEnded(from: decoder))
            case "events.unsubscribe.result": self = .eventsUnsubscribeResult(try EventsUnsubscribeResult(from: decoder))
            case "pane.terminal.open.result": self = .paneTerminalOpenResult(try PaneTerminalOpenResult(from: decoder))
            case "pane.terminal.frame": self = .paneTerminalFrame(try PaneTerminalFrame(from: decoder))
            case "pane.terminal.closed": self = .paneTerminalClosed(try PaneTerminalClosed(from: decoder))
            case "file.stat.result": self = .fileStatResult(try FileStatResult(from: decoder))
            case "file.read.result": self = .fileReadResult(try FileReadResult(from: decoder))
            case "push.status.result": self = .pushStatusResult(try PushStatusResult(from: decoder))
            case "push.install.result": self = .pushInstallResult(try PushInstallResult(from: decoder))
            case "push.remove.result": self = .pushRemoveResult(try PushRemoveResult(from: decoder))
            case "push.update_muted.result": self = .pushUpdateMutedResult(try PushUpdateMutedResult(from: decoder))
            case "push.test.result": self = .pushTestResult(try PushTestResult(from: decoder))
            case "workspace.create.result": self = .workspaceCreateResult(try WorkspaceCreateResult(from: decoder))
            case "workspace.rename.result": self = .workspaceRenameResult(try WorkspaceRenameResult(from: decoder))
            case "workspace.close.result": self = .workspaceCloseResult(try WorkspaceCloseResult(from: decoder))
            case "worktree.create.result": self = .worktreeCreateResult(try WorktreeCreateResult(from: decoder))
            case "agent.start.result": self = .agentStartResult(try AgentStartResult(from: decoder))
            case "file.upload.start.result": self = .fileUploadStartResult(try FileUploadStartResult(from: decoder))
            case "file.upload.chunk.result": self = .fileUploadChunkResult(try FileUploadChunkResult(from: decoder))
            case "devices.list.result": self = .devicesListResult(try DevicesListResult(from: decoder))
            case "devices.revoke.result": self = .devicesRevokeResult(try DevicesRevokeResult(from: decoder))
            case "host_service.status.result": self = .hostServiceStatusResult(try HostServiceStatusResult(from: decoder))
            case "host_service.update.result": self = .hostServiceUpdateResult(try HostServiceUpdateResult(from: decoder))
            case "host_service.set_auto_update.result": self = .hostServiceSetAutoUpdateResult(try HostServiceSetAutoUpdateResult(from: decoder))
            case "error": self = .errorMessage(try ErrorMessage(from: decoder))
            case "pane.read.result": self = .paneReadResult(try PaneReadResult(from: decoder))
            case "sessions.list.result": self = .sessionsListResult(try SessionsListResult(from: decoder))
            case "git.status.result": self = .gitStatusResult(try GitStatusResult(from: decoder))
            case "git.diff.result": self = .gitDiffResult(try GitDiffResult(from: decoder))
            case "queue.list.result": self = .queueListResult(try QueueListResult(from: decoder))
            case "queue.add.result": self = .queueAddResult(try QueueAddResult(from: decoder))
            case "queue.remove.result": self = .queueRemoveResult(try QueueRemoveResult(from: decoder))
            case "queue.reorder.result": self = .queueReorderResult(try QueueReorderResult(from: decoder))
            case "queue.changed": self = .queueChanged(try QueueChanged(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown message type \(type)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: TypeKey.self)
            switch self {
            case .welcome(let message):
                try container.encode("welcome", forKey: .type)
                try message.encode(to: encoder)
            case .agentsListResult(let message):
                try container.encode("agents.list.result", forKey: .type)
                try message.encode(to: encoder)
            case .paneSendKeysResult(let message):
                try container.encode("pane.send_keys.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptLocateResult(let message):
                try container.encode("transcript.locate.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptWindowResult(let message):
                try container.encode("transcript.window.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptFollowResult(let message):
                try container.encode("transcript.follow.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptUpdate(let message):
                try container.encode("transcript.update", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptUnfollowResult(let message):
                try container.encode("transcript.unfollow.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptPreviewsResult(let message):
                try container.encode("transcript.previews.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptSubagentResult(let message):
                try container.encode("transcript.subagent.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptWorkflowResult(let message):
                try container.encode("transcript.workflow.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptDelegationResult(let message):
                try container.encode("transcript.delegation.result", forKey: .type)
                try message.encode(to: encoder)
            case .paneSendTextResult(let message):
                try container.encode("pane.send_text.result", forKey: .type)
                try message.encode(to: encoder)
            case .agentPromptResult(let message):
                try container.encode("agent.prompt.result", forKey: .type)
                try message.encode(to: encoder)
            case .eventsSubscribeResult(let message):
                try container.encode("events.subscribe.result", forKey: .type)
                try message.encode(to: encoder)
            case .subscribedEvent(let message):
                try container.encode("events.event", forKey: .type)
                try message.encode(to: encoder)
            case .eventsEnded(let message):
                try container.encode("events.ended", forKey: .type)
                try message.encode(to: encoder)
            case .eventsUnsubscribeResult(let message):
                try container.encode("events.unsubscribe.result", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalOpenResult(let message):
                try container.encode("pane.terminal.open.result", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalFrame(let message):
                try container.encode("pane.terminal.frame", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalClosed(let message):
                try container.encode("pane.terminal.closed", forKey: .type)
                try message.encode(to: encoder)
            case .fileStatResult(let message):
                try container.encode("file.stat.result", forKey: .type)
                try message.encode(to: encoder)
            case .fileReadResult(let message):
                try container.encode("file.read.result", forKey: .type)
                try message.encode(to: encoder)
            case .pushStatusResult(let message):
                try container.encode("push.status.result", forKey: .type)
                try message.encode(to: encoder)
            case .pushInstallResult(let message):
                try container.encode("push.install.result", forKey: .type)
                try message.encode(to: encoder)
            case .pushRemoveResult(let message):
                try container.encode("push.remove.result", forKey: .type)
                try message.encode(to: encoder)
            case .pushUpdateMutedResult(let message):
                try container.encode("push.update_muted.result", forKey: .type)
                try message.encode(to: encoder)
            case .pushTestResult(let message):
                try container.encode("push.test.result", forKey: .type)
                try message.encode(to: encoder)
            case .workspaceCreateResult(let message):
                try container.encode("workspace.create.result", forKey: .type)
                try message.encode(to: encoder)
            case .workspaceRenameResult(let message):
                try container.encode("workspace.rename.result", forKey: .type)
                try message.encode(to: encoder)
            case .workspaceCloseResult(let message):
                try container.encode("workspace.close.result", forKey: .type)
                try message.encode(to: encoder)
            case .worktreeCreateResult(let message):
                try container.encode("worktree.create.result", forKey: .type)
                try message.encode(to: encoder)
            case .agentStartResult(let message):
                try container.encode("agent.start.result", forKey: .type)
                try message.encode(to: encoder)
            case .fileUploadStartResult(let message):
                try container.encode("file.upload.start.result", forKey: .type)
                try message.encode(to: encoder)
            case .fileUploadChunkResult(let message):
                try container.encode("file.upload.chunk.result", forKey: .type)
                try message.encode(to: encoder)
            case .devicesListResult(let message):
                try container.encode("devices.list.result", forKey: .type)
                try message.encode(to: encoder)
            case .devicesRevokeResult(let message):
                try container.encode("devices.revoke.result", forKey: .type)
                try message.encode(to: encoder)
            case .hostServiceStatusResult(let message):
                try container.encode("host_service.status.result", forKey: .type)
                try message.encode(to: encoder)
            case .hostServiceUpdateResult(let message):
                try container.encode("host_service.update.result", forKey: .type)
                try message.encode(to: encoder)
            case .hostServiceSetAutoUpdateResult(let message):
                try container.encode("host_service.set_auto_update.result", forKey: .type)
                try message.encode(to: encoder)
            case .errorMessage(let message):
                try container.encode("error", forKey: .type)
                try message.encode(to: encoder)
            case .paneReadResult(let message):
                try container.encode("pane.read.result", forKey: .type)
                try message.encode(to: encoder)
            case .sessionsListResult(let message):
                try container.encode("sessions.list.result", forKey: .type)
                try message.encode(to: encoder)
            case .gitStatusResult(let message):
                try container.encode("git.status.result", forKey: .type)
                try message.encode(to: encoder)
            case .gitDiffResult(let message):
                try container.encode("git.diff.result", forKey: .type)
                try message.encode(to: encoder)
            case .queueListResult(let message):
                try container.encode("queue.list.result", forKey: .type)
                try message.encode(to: encoder)
            case .queueAddResult(let message):
                try container.encode("queue.add.result", forKey: .type)
                try message.encode(to: encoder)
            case .queueRemoveResult(let message):
                try container.encode("queue.remove.result", forKey: .type)
                try message.encode(to: encoder)
            case .queueReorderResult(let message):
                try container.encode("queue.reorder.result", forKey: .type)
                try message.encode(to: encoder)
            case .queueChanged(let message):
                try container.encode("queue.changed", forKey: .type)
                try message.encode(to: encoder)
            }
        }
    }
}

extension HostServiceProtocol {
    /// 握手：連線後第一個請求，帶 app 使用的協定版本。
    public struct Hello: Codable, Sendable, Equatable {
        /// 請求識別碼，回應帶回同一個值。
        public var requestId: String
        public var protocolVersion: Int
        /// app 版本，只用於診斷。
        public var appVersion: String?

        public init(requestId: String, protocolVersion: Int, appVersion: String? = nil) {
            self.requestId = requestId
            self.protocolVersion = protocolVersion
            self.appVersion = appVersion
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case protocolVersion = "protocol_version"
            case appVersion = "app_version"
        }
    }
}

extension HostServiceProtocol {
    /// 握手成功：主機服務的協定版本、版本，herdr 伺服器 ping 回報的版本與能力，以及這支裝置是否唯讀。
    public struct Welcome: Codable, Sendable, Equatable {
        public var requestId: String
        public var protocolVersion: Int
        public var hostServiceVersion: String
        public var herdr: HerdrServer
        /// 這支裝置配對成唯讀：寫入類操作會被拒絕(read_only_device),app 停用輸入。
        public var readOnly: Bool

        public init(requestId: String, protocolVersion: Int, hostServiceVersion: String, herdr: HerdrServer, readOnly: Bool) {
            self.requestId = requestId
            self.protocolVersion = protocolVersion
            self.hostServiceVersion = hostServiceVersion
            self.herdr = herdr
            self.readOnly = readOnly
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case protocolVersion = "protocol_version"
            case hostServiceVersion = "host_service_version"
            case herdr
            case readOnly = "read_only"
        }
    }
}

extension HostServiceProtocol {
    /// herdr 伺服器(不是 CLI)的版本與能力。
    public struct HerdrServer: Codable, Sendable, Equatable {
        public var version: String
        public var `protocol`: Int
        /// ping 的 capabilities 裡值為 true 的名稱。
        public var capabilities: [String]

        public init(version: String, `protocol`: Int, capabilities: [String]) {
            self.version = version
            self.`protocol` = `protocol`
            self.capabilities = capabilities
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case `protocol`
            case capabilities
        }
    }
}

extension HostServiceProtocol {
    /// 取得 Agent 列表(herdr session.snapshot)。
    public struct AgentsList: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// Agent 列表與它們所在的 workspace。
    public struct AgentsListResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var workspaces: [Workspace]
        public var agents: [Agent]

        public init(requestId: String, workspaces: [Workspace], agents: [Agent]) {
            self.requestId = requestId
            self.workspaces = workspaces
            self.agents = agents
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case workspaces
            case agents
        }
    }
}

extension HostServiceProtocol {
    public struct Workspace: Codable, Sendable, Equatable {
        public var workspaceId: String
        public var label: String

        public init(workspaceId: String, label: String) {
            self.workspaceId = workspaceId
            self.label = label
        }

        private enum CodingKeys: String, CodingKey {
            case workspaceId = "workspace_id"
            case label
        }
    }
}

extension HostServiceProtocol {
    /// herdr 在某個 Pane 偵測到的 Agent。
    public struct Agent: Codable, Sendable, Equatable {
        public var paneId: String
        public var workspaceId: String
        public var tabId: String
        /// herdr 的 agent 名稱，例如 claude、codex。
        public var agent: String?
        public var status: AgentStatus
        /// 去掉狀態符號的終端機標題。
        public var title: String?
        public var cwd: String?
        public var session: AgentSession?

        public init(paneId: String, workspaceId: String, tabId: String, agent: String? = nil, status: AgentStatus, title: String? = nil, cwd: String? = nil, session: AgentSession? = nil) {
            self.paneId = paneId
            self.workspaceId = workspaceId
            self.tabId = tabId
            self.agent = agent
            self.status = status
            self.title = title
            self.cwd = cwd
            self.session = session
        }

        private enum CodingKeys: String, CodingKey {
            case paneId = "pane_id"
            case workspaceId = "workspace_id"
            case tabId = "tab_id"
            case agent
            case status
            case title
            case cwd
            case session
        }
    }
}

extension HostServiceProtocol {
    /// herdr 回報的 Agent 狀態。
    public enum AgentStatus: String, Codable, Sendable, CaseIterable {
        case idle
        case working
        case blocked
        case done
        case unknown
    }
}

extension HostServiceProtocol {
    /// herdr 的 agent_session:定位對話紀錄用。
    public struct AgentSession: Codable, Sendable, Equatable {
        public var source: String
        public var agent: String
        public var kind: String
        public var value: String

        public init(source: String, agent: String, kind: String, value: String) {
            self.source = source
            self.agent = agent
            self.kind = kind
            self.value = value
        }

        private enum CodingKeys: String, CodingKey {
            case source
            case agent
            case kind
            case value
        }
    }
}

extension HostServiceProtocol {
    /// 對 Pane 送出按鍵(herdr pane.send_keys)。
    public struct PaneSendKeys: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        /// herdr 鍵名，例如 enter、esc、ctrl+c。
        public var keys: [String]
        /// app 看到的 herdr agent_session id(raychiutw/purrdr.host#29)。帶了就先讀 session.snapshot 比對，這個 pane 的 Agent session 不同(或已沒有 Agent)時不送，回 pane_changed;沒帶時照送。
        public var expectedSession: String?
        /// app 看到的畫面指紋(pane.read 以 source visible、format text 回的 screen)。帶了就先讀畫面比對，不同時不送，回 pane_changed;回答選擇題時用。
        public var expectedScreen: String?

        public init(requestId: String, paneId: String, keys: [String], expectedSession: String? = nil, expectedScreen: String? = nil) {
            self.requestId = requestId
            self.paneId = paneId
            self.keys = keys
            self.expectedSession = expectedSession
            self.expectedScreen = expectedScreen
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case keys
            case expectedSession = "expected_session"
            case expectedScreen = "expected_screen"
        }
    }
}

extension HostServiceProtocol {
    /// 按鍵已送到 Pane。
    public struct PaneSendKeysResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 開 Pane 終端機(ADR-0005):主機服務以子行程執行 herdr terminal session control;唯讀裝置改用 observe(只能看)。串流識別碼就是這個請求的 request_id。
    public struct PaneTerminalOpen: Codable, Sendable, Equatable {
        public var requestId: String
        /// pane id 或 terminal id。
        public var target: String
        public var columns: Int
        public var rows: Int
        /// 接管別人正在操作的 Pane(唯讀裝置忽略)。
        public var takeover: Bool?

        public init(requestId: String, target: String, columns: Int, rows: Int, takeover: Bool? = nil) {
            self.requestId = requestId
            self.target = target
            self.columns = columns
            self.rows = rows
            self.takeover = takeover
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case target
            case columns
            case rows
            case takeover
        }
    }
}

extension HostServiceProtocol {
    /// Pane 終端機已開啟;畫面更新接著以 pane.terminal.frame 送出，結束時送 pane.terminal.closed。
    public struct PaneTerminalOpenResult: Codable, Sendable, Equatable {
        public var requestId: String
        /// 等於開啟請求的 request_id。
        public var streamId: String
        /// 唯讀裝置以 observe 接上：只能看，輸入會被拒絕。
        public var readOnly: Bool

        public init(requestId: String, streamId: String, readOnly: Bool) {
            self.requestId = requestId
            self.streamId = streamId
            self.readOnly = readOnly
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
            case readOnly = "read_only"
        }
    }
}

extension HostServiceProtocol {
    /// 一次畫面更新:herdr terminal.frame 原樣轉接。
    public struct PaneTerminalFrame: Codable, Sendable, Equatable {
        public var streamId: String
        /// 每條連線從 1 起算。
        public var seq: Int
        public var width: Int
        public var height: Int
        /// true 是完整重繪。
        public var full: Bool
        /// ANSI 畫面 bytes 的標準 base64。
        public var bytes: String

        public init(streamId: String, seq: Int, width: Int, height: Int, full: Bool, bytes: String) {
            self.streamId = streamId
            self.seq = seq
            self.width = width
            self.height = height
            self.full = full
            self.bytes = bytes
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case seq
            case width
            case height
            case full
            case bytes
        }
    }
}

extension HostServiceProtocol {
    /// Pane 終端機結束，之後這個串流不再有訊息。
    public struct PaneTerminalClosed: Codable, Sendable, Equatable {
        public var streamId: String
        public var ending: PaneTerminalEnding
        /// ending 是 closed 時,herdr terminal.closed 的原文。
        public var reason: String?
        /// ending 是 failed 時,herdr 的 exit code。
        public var exitCode: Int?
        /// ending 是 failed 時,herdr 的 stderr(給開發者看)。
        public var message: String?

        public init(streamId: String, ending: PaneTerminalEnding, reason: String? = nil, exitCode: Int? = nil, message: String? = nil) {
            self.streamId = streamId
            self.ending = ending
            self.reason = reason
            self.exitCode = exitCode
            self.message = message
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case ending
            case reason
            case exitCode = "exit_code"
            case message
        }
    }
}

extension HostServiceProtocol {
    /// closed:herdr 送了 terminal.closed;disconnected:沒有 terminal.closed 就斷了(可重新連線);failed:herdr 沒跑起來。
    public enum PaneTerminalEnding: String, Codable, Sendable, CaseIterable {
        case closed
        case disconnected
        case failed
    }
}

extension HostServiceProtocol {
    /// Pane 終端機的鍵盤輸入(herdr terminal.input)。不回應;稽核只在開啟時記一筆，不記內容。
    public struct PaneTerminalInput: Codable, Sendable, Equatable {
        public var streamId: String
        /// 輸入 bytes 的標準 base64,每則不超過 64 KiB。
        public var bytes: String

        public init(streamId: String, bytes: String) {
            self.streamId = streamId
            self.bytes = bytes
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case bytes
        }
    }
}

extension HostServiceProtocol {
    /// 改變 viewport 格數(herdr terminal.resize)。不回應。
    public struct PaneTerminalResize: Codable, Sendable, Equatable {
        public var streamId: String
        public var columns: Int
        public var rows: Int

        public init(streamId: String, columns: Int, rows: Int) {
            self.streamId = streamId
            self.columns = columns
            self.rows = rows
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case columns
            case rows
        }
    }
}

extension HostServiceProtocol {
    /// 捲動(herdr terminal.scroll)。source 沒帶時是 wheel。不回應。
    public struct PaneTerminalScroll: Codable, Sendable, Equatable {
        public var streamId: String
        public var direction: TerminalScrollDirection
        public var lines: Int
        public var column: Int
        public var row: Int
        public var source: TerminalScrollSource?

        public init(streamId: String, direction: TerminalScrollDirection, lines: Int, column: Int, row: Int, source: TerminalScrollSource? = nil) {
            self.streamId = streamId
            self.direction = direction
            self.lines = lines
            self.column = column
            self.row = row
            self.source = source
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case direction
            case lines
            case column
            case row
            case source
        }
    }
}

extension HostServiceProtocol {
    /// 捲動方向。
    public enum TerminalScrollDirection: String, Codable, Sendable, CaseIterable {
        case up
        case down
    }
}

extension HostServiceProtocol {
    /// 捲動來源:wheel 是滾輪或單指滑動;page_key 是實體鍵盤 Page Up／Down,herdr 依 Pane 狀態捲主機 scrollback 或送 Page 鍵給程式。
    public enum TerminalScrollSource: String, Codable, Sendable, CaseIterable {
        case wheel
        case pageKey = "page_key"
    }
}

extension HostServiceProtocol {
    /// 關閉 Pane 終端機:control 關閉 stdin(等同 release),observe 結束子行程。不回應。
    public struct PaneTerminalClose: Codable, Sendable, Equatable {
        public var streamId: String

        public init(streamId: String) {
            self.streamId = streamId
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
        }
    }
}

extension HostServiceProtocol {
    /// 定位對話紀錄(#59)。session 必須是 herdr snapshot 目前某個 Agent 的 agent_session;格式與 cwd 由主機服務從 snapshot 取得，app 不能指定路徑。
    public struct TranscriptLocate: Codable, Sendable, Equatable {
        public var requestId: String
        public var session: SessionReference
        /// 是否一併回傳檔案前兩行(Codex、Pi／OMP 的 header 檢查)。
        public var header: Bool

        public init(requestId: String, session: SessionReference, header: Bool) {
            self.requestId = requestId
            self.session = session
            self.header = header
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case session
            case header
        }
    }
}

extension HostServiceProtocol {
    /// herdr agent_session 的 kind 與 value。
    public struct SessionReference: Codable, Sendable, Equatable {
        /// id 或 path。
        public var kind: String
        public var value: String

        public init(kind: String, value: String) {
            self.kind = kind
            self.value = value
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case value
        }
    }
}

extension HostServiceProtocol {
    /// 對話紀錄的路徑與大小(byte)。之後這條連線才能以這個路徑讀視窗與追蹤。
    public struct TranscriptLocateResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var path: String
        public var size: Int
        /// 請求 header 時，檔案前兩行(原樣)。
        public var header: [String]?

        public init(requestId: String, path: String, size: Int, header: [String]? = nil) {
            self.requestId = requestId
            self.path = path
            self.size = size
            self.header = header
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case path
            case size
            case header
        }
    }
}

extension HostServiceProtocol {
    /// 讀以 end 為終點的最後 lines 行完整的行(開啟與往上翻頁)。path 必須是這條連線定位過的。
    public struct TranscriptWindow: Codable, Sendable, Equatable {
        public var requestId: String
        public var path: String
        public var end: Int
        public var lines: Int
        /// byte 上限(raychiutw/purrdr.host#52,0.11.0 起;app 打開聊天的短載入):只取 end 往前 max_bytes bytes 內完整的行，不放大範圍，所以回應的行數可能少於 lines;最後一行就比上限大時範圍是空的(start == end,由 app 決定要不要放寬)。同 SSH 視窗腳本的第五個參數。沒帶時照舊只依行數。0 或負數回 invalid_message。
        public var maxBytes: Int?

        public init(requestId: String, path: String, end: Int, lines: Int, maxBytes: Int? = nil) {
            self.requestId = requestId
            self.path = path
            self.end = end
            self.lines = lines
            self.maxBytes = maxBytes
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case path
            case end
            case lines
            case maxBytes = "max_bytes"
        }
    }
}

extension HostServiceProtocol {
    /// 視窗的 byte 範圍與範圍內的行。
    public struct TranscriptWindowResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var start: Int
        public var end: Int
        public var records: [TranscriptRecord]

        public init(requestId: String, start: Int, end: Int, records: [TranscriptRecord]) {
            self.requestId = requestId
            self.start = start
            self.end = end
            self.records = records
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case start
            case end
            case records
        }
    }
}

extension HostServiceProtocol {
    /// 對話紀錄的一行：原始 byte 長度(不含換行)與剝除圖片後的內容(行為規格 R-B04、R-B06)。
    public struct TranscriptRecord: Codable, Sendable, Equatable {
        public var length: Int
        public var text: String

        public init(length: Int, text: String) {
            self.length = length
            self.text = text
        }

        private enum CodingKeys: String, CodingKey {
            case length
            case text
        }
    }
}

extension HostServiceProtocol {
    /// 開始追蹤對話紀錄尾端：從 from 起，主機服務把新增的完整行(每則最多 limit bytes,落後很多時分段接著送)以 transcript.update 推送，直到 transcript.unfollow、追蹤結束或連線關閉。stream_id 由 app 指定，同一條連線內不可重複。path 必須是這條連線定位過的。
    public struct TranscriptFollow: Codable, Sendable, Equatable {
        public var requestId: String
        public var streamId: String
        public var path: String
        public var from: Int
        /// 每則回應或推送的上限(byte,#173):落後超過時從游標分段送出，每次最多 limit bytes 的完整行，後面還有就下一次接著送;第一行就超過 limit 時只送那一行，剝除圖片後的內容截短到 limit bytes(length 照原始長度，游標照樣前進)。#173 之前的主機服務落後超過 limit 就以 too_far_behind 結束。
        public var limit: Int

        public init(requestId: String, streamId: String, path: String, from: Int, limit: Int) {
            self.requestId = requestId
            self.streamId = streamId
            self.path = path
            self.from = from
            self.limit = limit
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
            case path
            case from
            case limit
        }
    }
}

extension HostServiceProtocol {
    /// 追蹤開始，帶目前的大小與 from 之後已有的完整行;ended 有值時主機服務沒有開始追蹤。
    public struct TranscriptFollowResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var streamId: String
        public var size: Int
        /// records 第一行的位置(byte)。
        public var start: Int
        public var records: [TranscriptRecord]
        public var ended: TranscriptStreamEnd?

        public init(requestId: String, streamId: String, size: Int, start: Int, records: [TranscriptRecord], ended: TranscriptStreamEnd? = nil) {
            self.requestId = requestId
            self.streamId = streamId
            self.size = size
            self.start = start
            self.records = records
            self.ended = ended
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
            case size
            case start
            case records
            case ended
        }
    }
}

extension HostServiceProtocol {
    /// 追蹤中的對話紀錄有了新的完整行，或追蹤結束(ended)。主機服務主動推送，沒有 request_id。
    public struct TranscriptUpdate: Codable, Sendable, Equatable {
        public var streamId: String
        public var size: Int
        /// records 第一行的位置(byte)。
        public var start: Int
        public var records: [TranscriptRecord]
        public var ended: TranscriptStreamEnd?

        public init(streamId: String, size: Int, start: Int, records: [TranscriptRecord], ended: TranscriptStreamEnd? = nil) {
            self.streamId = streamId
            self.size = size
            self.start = start
            self.records = records
            self.ended = ended
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case size
            case start
            case records
            case ended
        }
    }
}

extension HostServiceProtocol {
    /// 主機服務停止追蹤的原因:shrank 檔案變小(換新)、replaced 檔案被換成同長或更長的新檔(游標前的內容變了)、absent 檔案不見了、unreadable 讀不到。too_far_behind 只有 #173 之前的主機服務會送(落後超過 limit;現在改為分段送出),app 仍要能接受。
    public enum TranscriptStreamEnd: String, Codable, Sendable, CaseIterable {
        case shrank
        case replaced
        case tooFarBehind = "too_far_behind"
        case absent
        case unreadable
    }
}

extension HostServiceProtocol {
    /// 停止追蹤(對話關閉)。
    public struct TranscriptUnfollow: Codable, Sendable, Equatable {
        public var requestId: String
        public var streamId: String

        public init(requestId: String, streamId: String) {
            self.requestId = requestId
            self.streamId = streamId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
        }
    }
}

extension HostServiceProtocol {
    /// 已停止追蹤;之後不再推送這個 stream_id。
    public struct TranscriptUnfollowResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 列表預覽(raychiutw/purrdr.host#17):一次讀多個對話紀錄的檔尾。path 必須是這條連線定位過的，任一個不是就整個請求回 transcript_not_allowed。
    public struct TranscriptPreviews: Codable, Sendable, Equatable {
        public var requestId: String
        public var entries: [TranscriptPreviewEntry]

        public init(requestId: String, entries: [TranscriptPreviewEntry]) {
            self.requestId = requestId
            self.entries = entries
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case entries
        }
    }
}

extension HostServiceProtocol {
    /// 一個要讀預覽的對話紀錄。known_version 是上次這個主機服務回的 version(app 原樣帶回，不解讀)。
    public struct TranscriptPreviewEntry: Codable, Sendable, Equatable {
        public var key: String
        public var path: String
        public var knownVersion: String?

        public init(key: String, path: String, knownVersion: String? = nil) {
            self.key = key
            self.path = path
            self.knownVersion = knownVersion
        }

        private enum CodingKeys: String, CodingKey {
            case key
            case path
            case knownVersion = "known_version"
        }
    }
}

extension HostServiceProtocol {
    /// 每個讀得到的對話紀錄一項(讀不到的不在結果裡，同 SSH 的預覽腳本)。
    public struct TranscriptPreviewsResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var previews: [TranscriptPreview]

        public init(requestId: String, previews: [TranscriptPreview]) {
            self.requestId = requestId
            self.previews = previews
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case previews
        }
    }
}

extension HostServiceProtocol {
    /// 一個對話紀錄的預覽。records 同其他對話紀錄讀取，每行是原始長度與剝除圖片後的內容:whole 是最後 48000 bytes(第一行可能被切在中間，長度從切點算起)、appended 是 known_version 之後附加的部分、unchanged 沒有內容。
    public struct TranscriptPreview: Codable, Sendable, Equatable {
        public var key: String
        public var change: TranscriptPreviewChange
        public var version: String
        public var records: [TranscriptRecord]

        public init(key: String, change: TranscriptPreviewChange, version: String, records: [TranscriptRecord]) {
            self.key = key
            self.change = change
            self.version = version
            self.records = records
        }

        private enum CodingKeys: String, CodingKey {
            case key
            case change
            case version
            case records
        }
    }
}

extension HostServiceProtocol {
    /// 這次讀到的範圍:unchanged 與 known_version 相同、appended 只有附加的部分、whole 整段檔尾。
    public enum TranscriptPreviewChange: String, Codable, Sendable, CaseIterable {
        case unchanged
        case appended
        case whole
    }
}

extension HostServiceProtocol {
    /// 找呼叫 call_id 啟動的 subagent 對話紀錄(raychiutw/purrdr.host#17):在 path 的 session 資料夾的 subagents/ 下找 toolUseId 完全等於 call_id 的 agent-*.meta.json。path 必須是這條連線可讀的對話紀錄。沒有 meta 回 transcript_absent,不只一個回 transcript_ambiguous。
    public struct TranscriptSubagent: Codable, Sendable, Equatable {
        public var requestId: String
        public var path: String
        public var callId: String

        public init(requestId: String, path: String, callId: String) {
            self.requestId = requestId
            self.path = path
            self.callId = callId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case path
            case callId = "call_id"
        }
    }
}

extension HostServiceProtocol {
    /// subagent 對話紀錄的路徑。session 資料夾 subagents/ 底下的 .jsonl 都可以讀視窗與追蹤。
    public struct TranscriptSubagentResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var path: String

        public init(requestId: String, path: String) {
            self.requestId = requestId
            self.path = path
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case path
        }
    }
}

extension HostServiceProtocol {
    /// 讀 workflow 進度(raychiutw/purrdr.host#17):path 的 session 資料夾的 workflows/<run_id>.json(結束才寫)優先，否則 subagents/workflows/<run_id>/journal.jsonl。兩個都沒有回 transcript_absent。
    public struct TranscriptWorkflow: Codable, Sendable, Equatable {
        public var requestId: String
        public var path: String
        public var runId: String
        /// 上次回的 checksum;相同時不回內容。
        public var knownChecksum: String?

        public init(requestId: String, path: String, runId: String, knownChecksum: String? = nil) {
            self.requestId = requestId
            self.path = path
            self.runId = runId
            self.knownChecksum = knownChecksum
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case path
            case runId = "run_id"
            case knownChecksum = "known_checksum"
        }
    }
}

extension HostServiceProtocol {
    /// kind 是讀到哪個檔(run 或 journal);content 是檔案原樣內容，checksum 等於 known_checksum 時省略。
    public struct TranscriptWorkflowResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var kind: TranscriptWorkflowKind
        public var checksum: String
        public var content: String?

        public init(requestId: String, kind: TranscriptWorkflowKind, checksum: String, content: String? = nil) {
            self.requestId = requestId
            self.kind = kind
            self.checksum = checksum
            self.content = content
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case kind
            case checksum
            case content
        }
    }
}

extension HostServiceProtocol {
    /// run:workflows/<run_id>.json;journal:subagents/workflows/<run_id>/journal.jsonl。
    public enum TranscriptWorkflowKind: String, Codable, Sendable, CaseIterable {
        case run
        case journal
    }
}

extension HostServiceProtocol {
    /// 父對話紀錄中含 call_id 或 agent_id 的行(委派是否結束，raychiutw/purrdr.host#17)。path 必須是這條連線可讀的對話紀錄。
    public struct TranscriptDelegation: Codable, Sendable, Equatable {
        public var requestId: String
        public var path: String
        public var callId: String
        public var agentId: String?
        /// 上次回的 checksum;相同時不回內容。
        public var knownChecksum: String?

        public init(requestId: String, path: String, callId: String, agentId: String? = nil, knownChecksum: String? = nil) {
            self.requestId = requestId
            self.path = path
            self.callId = callId
            self.agentId = agentId
            self.knownChecksum = knownChecksum
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case path
            case callId = "call_id"
            case agentId = "agent_id"
            case knownChecksum = "known_checksum"
        }
    }
}

extension HostServiceProtocol {
    /// 這些行(剝除圖片後)的 checksum 與行;checksum 等於 known_checksum 時省略 records。
    public struct TranscriptDelegationResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var checksum: String
        public var records: [TranscriptRecord]?

        public init(requestId: String, checksum: String, records: [TranscriptRecord]? = nil) {
            self.requestId = requestId
            self.checksum = checksum
            self.records = records
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case checksum
            case records
        }
    }
}

extension HostServiceProtocol {
    /// 對 Pane 送出文字(herdr pane.send_text),不補 Enter。
    public struct PaneSendText: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        public var text: String
        /// app 看到的 herdr agent_session id(raychiutw/purrdr.host#29)。帶了就先讀 session.snapshot 比對，這個 pane 的 Agent session 不同(或已沒有 Agent)時不送，回 pane_changed;沒帶時照送。
        public var expectedSession: String?
        /// app 看到的畫面指紋(pane.read 以 source visible、format text 回的 screen)。帶了就先讀畫面比對，不同時不送，回 pane_changed;回答選擇題時用。
        public var expectedScreen: String?

        public init(requestId: String, paneId: String, text: String, expectedSession: String? = nil, expectedScreen: String? = nil) {
            self.requestId = requestId
            self.paneId = paneId
            self.text = text
            self.expectedSession = expectedSession
            self.expectedScreen = expectedScreen
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case text
            case expectedSession = "expected_session"
            case expectedScreen = "expected_screen"
        }
    }
}

extension HostServiceProtocol {
    /// 文字已送到 Pane。
    public struct PaneSendTextResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 讀 Pane 畫面(herdr pane.read,raychiutw/purrdr.host#28)。主機服務只轉送並回傳文字與畫面指紋，不解析語意;pane_id 規則同 Pane 終端機的 target。
    public struct PaneRead: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        public var source: PaneReadSource
        public var format: PaneReadFormat?
        /// recent／recent_unwrapped 的行數(照 herdr);沒帶時由 herdr 決定。
        public var lines: Int?

        public init(requestId: String, paneId: String, source: PaneReadSource, format: PaneReadFormat? = nil, lines: Int? = nil) {
            self.requestId = requestId
            self.paneId = paneId
            self.source = source
            self.format = format
            self.lines = lines
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case source
            case format
            case lines
        }
    }
}

extension HostServiceProtocol {
    /// 照 herdr:visible 可見區、recent 最近輸出、recent_unwrapped 不折行的最近輸出、detection herdr 判斷狀態用的區段。
    public enum PaneReadSource: String, Codable, Sendable, CaseIterable {
        case visible
        case recent
        case recentUnwrapped = "recent_unwrapped"
        case detection
    }
}

extension HostServiceProtocol {
    /// text 去掉 ANSI(預設);ansi 保留 ANSI 跳脫序列。
    public enum PaneReadFormat: String, Codable, Sendable, CaseIterable {
        case text
        case ansi
    }
}

extension HostServiceProtocol {
    /// 畫面文字與指紋。screen 是 text 的 UTF-8 bytes 的 SHA-256(小寫 hex);以 source visible、format text 讀到的 screen 可作為 expected_screen。
    public struct PaneReadResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var text: String
        public var screen: String
        /// herdr 截短了輸出。
        public var truncated: Bool

        public init(requestId: String, text: String, screen: String, truncated: Bool) {
            self.requestId = requestId
            self.text = text
            self.screen = screen
            self.truncated = truncated
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case text
            case screen
            case truncated
        }
    }
}

extension HostServiceProtocol {
    /// 對 Agent 送出 prompt(herdr agent.prompt,target 是 pane_id)。
    public struct AgentPrompt: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        public var text: String
        public var wait: PromptWait?
        /// app 看到的 herdr agent_session id(raychiutw/purrdr.host#29)。帶了就先讀 session.snapshot 比對，這個 pane 的 Agent session 不同(或已沒有 Agent)時不送，回 pane_changed;沒帶時照送。
        public var expectedSession: String?
        /// app 看到的畫面指紋(pane.read 以 source visible、format text 回的 screen)。帶了就先讀畫面比對，不同時不送，回 pane_changed;回答選擇題時用。
        public var expectedScreen: String?

        public init(requestId: String, paneId: String, text: String, wait: PromptWait? = nil, expectedSession: String? = nil, expectedScreen: String? = nil) {
            self.requestId = requestId
            self.paneId = paneId
            self.text = text
            self.wait = wait
            self.expectedSession = expectedSession
            self.expectedScreen = expectedScreen
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case text
            case wait
            case expectedSession = "expected_session"
            case expectedScreen = "expected_screen"
        }
    }
}

extension HostServiceProtocol {
    /// herdr agent.prompt 的 wait:等 Agent 進入其中一個狀態;主機服務等 herdr 的時間隨 timeout_ms 延長。
    public struct PromptWait: Codable, Sendable, Equatable {
        public var until: [AgentStatus]
        public var timeoutMs: Int

        public init(until: [AgentStatus], timeoutMs: Int) {
            self.until = until
            self.timeoutMs = timeoutMs
        }

        private enum CodingKeys: String, CodingKey {
            case until
            case timeoutMs = "timeout_ms"
        }
    }
}

extension HostServiceProtocol {
    /// herdr 收下 prompt。等待逾時、Agent 在等回答等情況以 herdr_error 回報(herdr_code 如 timeout、agent_blocked)。
    public struct AgentPromptResult: Codable, Sendable, Equatable {
        public var requestId: String
        /// herdr 回報的送達方式(例如 written_to_pty);沒有時省略。
        public var delivery: String?

        public init(requestId: String, delivery: String? = nil) {
            self.requestId = requestId
            self.delivery = delivery
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case delivery
        }
    }
}

extension HostServiceProtocol {
    /// 在主機上的資料夾建立 workspace(herdr workspace.create,不搶桌機焦點)。cwd 必須是主機上存在的絕對路徑資料夾(herdr 遇到不存在的資料夾會改開家目錄，所以主機服務先檢查)。新增聊天 = workspace.create 後對 root pane 送 agent.start。
    public struct WorkspaceCreate: Codable, Sendable, Equatable {
        public var requestId: String
        /// 主機上的絕對路徑。
        public var cwd: String
        /// workspace 名稱;省略時由 herdr 以資料夾名命名。
        public var label: String?

        public init(requestId: String, cwd: String, label: String? = nil) {
            self.requestId = requestId
            self.cwd = cwd
            self.label = label
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case cwd
            case label
        }
    }
}

extension HostServiceProtocol {
    /// workspace 已建立;聊天開在 root_pane_id。
    public struct WorkspaceCreateResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var workspaceId: String
        public var rootPaneId: String

        public init(requestId: String, workspaceId: String, rootPaneId: String) {
            self.requestId = requestId
            self.workspaceId = workspaceId
            self.rootPaneId = rootPaneId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case workspaceId = "workspace_id"
            case rootPaneId = "root_pane_id"
        }
    }
}

extension HostServiceProtocol {
    /// 重新命名 workspace(herdr workspace.rename)。
    public struct WorkspaceRename: Codable, Sendable, Equatable {
        public var requestId: String
        public var workspaceId: String
        /// 新名稱，不可空白。
        public var label: String

        public init(requestId: String, workspaceId: String, label: String) {
            self.requestId = requestId
            self.workspaceId = workspaceId
            self.label = label
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case workspaceId = "workspace_id"
            case label
        }
    }
}

extension HostServiceProtocol {
    /// 已重新命名。
    public struct WorkspaceRenameResult: Codable, Sendable, Equatable {
        public var requestId: String
        /// herdr 實際保存的名稱(可能經正規化);沒有時省略。
        public var label: String?

        public init(requestId: String, label: String? = nil) {
            self.requestId = requestId
            self.label = label
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case label
        }
    }
}

extension HostServiceProtocol {
    /// 關閉 workspace(herdr workspace.close):裡面的 tab、pane 與程序都會停止。不連同 worktree 群組一起關，同 repo 的 worktree workspace 還開著時以 herdr_error 回報(herdr_code workspace_group_close_required)。
    public struct WorkspaceClose: Codable, Sendable, Equatable {
        public var requestId: String
        public var workspaceId: String

        public init(requestId: String, workspaceId: String) {
            self.requestId = requestId
            self.workspaceId = workspaceId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case workspaceId = "workspace_id"
        }
    }
}

extension HostServiceProtocol {
    /// 已關閉。
    public struct WorkspaceCloseResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 以 workspace 所在的 git repo 建立 worktree 與分支，開成新的 workspace(herdr worktree.create,不搶桌機焦點)。分支已存在時 herdr 直接 checkout。不在 git repo 裡時以 herdr_error 回報(herdr_code not_git_worktree)。
    public struct WorktreeCreate: Codable, Sendable, Equatable {
        public var requestId: String
        /// 以這個 workspace 的 repo 為底。
        public var workspaceId: String
        /// 分支名稱：不能以 - 開頭，不含空白、控制字元或 ..。
        public var branch: String

        public init(requestId: String, workspaceId: String, branch: String) {
            self.requestId = requestId
            self.workspaceId = workspaceId
            self.branch = branch
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case workspaceId = "workspace_id"
            case branch
        }
    }
}

extension HostServiceProtocol {
    /// worktree 已建立並開成新的 workspace;聊天開在 root_pane_id。
    public struct WorktreeCreateResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var workspaceId: String
        public var rootPaneId: String

        public init(requestId: String, workspaceId: String, rootPaneId: String) {
            self.requestId = requestId
            self.workspaceId = workspaceId
            self.rootPaneId = rootPaneId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case workspaceId = "workspace_id"
            case rootPaneId = "root_pane_id"
        }
    }
}

extension HostServiceProtocol {
    /// 在 pane 的 shell 啟動 Agent(herdr agent.start)。新增聊天 = workspace.create 或 worktree.create 後對 root pane 送這個。不接受任意參數：只有 Claude Code 可帶 permission_mode(轉成 --permission-mode),Claude Code 與 Codex 可帶 resume_session。主機服務等 herdr 的時間隨 timeout_ms 延長;Agent 停在啟動問題、pane 不在 shell 提示字元等以 herdr_error 回報(herdr_code 如 agent_not_ready、agent_pane_busy、agent_name_taken)。
    public struct AgentStart: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        /// herdr 的 Agent 名稱：英數字、-、_、.,不能以 - 開頭。
        public var name: String
        /// herdr 的 Agent 種類(herdr agent start --kind,例如 claude、codex),只有小寫英文字母與數字。
        public var kind: String
        public var permissionMode: ClaudePermissionMode?
        /// 續接的 session id(sessions.list 的 id;英數字與 -),只限 claude(轉成 --resume)與 codex(轉成 resume 子指令)。主機服務先確認這個 session 的對話紀錄存在，不在時回 transcript_absent、不啟動(herdr 對不存在的 session 一樣回已啟動，Agent 隨即結束)。
        public var resumeSession: String?
        /// 等 Agent 就緒的時間;省略時用 herdr 的預設(30 秒)。
        public var timeoutMs: Int?

        public init(requestId: String, paneId: String, name: String, kind: String, permissionMode: ClaudePermissionMode? = nil, resumeSession: String? = nil, timeoutMs: Int? = nil) {
            self.requestId = requestId
            self.paneId = paneId
            self.name = name
            self.kind = kind
            self.permissionMode = permissionMode
            self.resumeSession = resumeSession
            self.timeoutMs = timeoutMs
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case name
            case kind
            case permissionMode = "permission_mode"
            case resumeSession = "resume_session"
            case timeoutMs = "timeout_ms"
        }
    }
}

extension HostServiceProtocol {
    /// Claude Code 的 --permission-mode。省略時沿用使用者在主機上的設定。
    public enum ClaudePermissionMode: String, Codable, Sendable, CaseIterable {
        case manual
        case acceptEdits
        case plan
        case auto
        case bypassPermissions
    }
}

extension HostServiceProtocol {
    /// Agent 已在 pane 啟動。
    public struct AgentStartResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 列出工作資料夾過去的 Claude／Codex session(raychiutw/purrdr.host#32),給續接用。Claude 讀 <設定目錄>/projects/<cwd 轉成的資料夾名>/*.jsonl;Codex 讀 sessions/ 下 session_meta 的 cwd 等於這個資料夾的 rollout。只回 id、最後修改時間與第一則使用者訊息的摘要，依修改時間新到舊，最多 50 筆。
    public struct SessionsList: Codable, Sendable, Equatable {
        public var requestId: String
        /// 絕對路徑。
        public var cwd: String
        public var agentKind: ResumableAgentKind

        public init(requestId: String, cwd: String, agentKind: ResumableAgentKind) {
            self.requestId = requestId
            self.cwd = cwd
            self.agentKind = agentKind
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case cwd
            case agentKind = "agent_kind"
        }
    }
}

extension HostServiceProtocol {
    /// 可以續接 session 的 Agent。
    public enum ResumableAgentKind: String, Codable, Sendable, CaseIterable {
        case claude
        case codex
    }
}

extension HostServiceProtocol {
    /// 可續接的 session;資料夾不在時是空的。
    public struct SessionsListResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var sessions: [HistorySession]

        public init(requestId: String, sessions: [HistorySession]) {
            self.requestId = requestId
            self.sessions = sessions
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case sessions
        }
    }
}

extension HostServiceProtocol {
    /// 唯讀的 git 變更清單(raychiutw/purrdr.host#33):cwd 所在 repo 的工作目錄相對 HEAD 改了哪些檔案。cwd 必須是 herdr session.snapshot 當下回報的 Agent 工作目錄;以程序內函式庫讀取，不執行 git 或任何 filter 程式(所以不套用 clean／smudge 與換行轉換)。
    public struct GitStatus: Codable, Sendable, Equatable {
        public var requestId: String
        public var cwd: String

        public init(requestId: String, cwd: String) {
            self.requestId = requestId
            self.cwd = cwd
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case cwd
        }
    }
}

extension HostServiceProtocol {
    /// 變更的檔案，依路徑排序。
    public struct GitStatusResult: Codable, Sendable, Equatable {
        public var requestId: String
        /// 目前分支的短名稱;detached HEAD 時省略。
        public var branch: String?
        public var files: [GitFileChange]

        public init(requestId: String, branch: String? = nil, files: [GitFileChange]) {
            self.requestId = requestId
            self.branch = branch
            self.files = files
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case branch
            case files
        }
    }
}

extension HostServiceProtocol {
    /// 一個變更的檔案;path 相對 repo 根目錄，以 / 分隔。
    public struct GitFileChange: Codable, Sendable, Equatable {
        public var path: String
        public var change: GitChangeKind

        public init(path: String, change: GitChangeKind) {
            self.path = path
            self.change = change
        }

        private enum CodingKeys: String, CodingKey {
            case path
            case change
        }
    }
}

extension HostServiceProtocol {
    /// 相對 HEAD:added 已加入 index 的新檔、modified 內容不同、deleted 工作目錄沒有了、untracked 沒加入 index 也沒被 .gitignore 排除的新檔。
    public enum GitChangeKind: String, Codable, Sendable, CaseIterable {
        case added
        case modified
        case deleted
        case untracked
    }
}

extension HostServiceProtocol {
    /// 唯讀的 git diff(工作目錄相對 HEAD 的 unified diff,前後 3 行)。cwd 規則同 git.status;帶 path 時只回這個檔案(必須是變更清單裡的路徑)。
    public struct GitDiff: Codable, Sendable, Equatable {
        public var requestId: String
        public var cwd: String
        /// 相對 repo 根目錄的路徑，以 / 分隔。
        public var path: String?

        public init(requestId: String, cwd: String, path: String? = nil) {
            self.requestId = requestId
            self.cwd = cwd
            self.path = path
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case cwd
            case path
        }
    }
}

extension HostServiceProtocol {
    /// 每個變更檔案的 diff。所有 diff 文字合計超過 x-maximum-file-size 時，之後的檔案只列路徑並標 truncated。
    public struct GitDiffResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var files: [GitFileDiff]
        public var truncated: Bool

        public init(requestId: String, files: [GitFileDiff], truncated: Bool) {
            self.requestId = requestId
            self.files = files
            self.truncated = truncated
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case files
            case truncated
        }
    }
}

extension HostServiceProtocol {
    /// 一個檔案的 diff;沒有 diff 文字時 omitted 說明原因。
    public struct GitFileDiff: Codable, Sendable, Equatable {
        public var path: String
        public var change: GitChangeKind
        /// unified diff 的 hunk(@@ 開頭，不含 ---／+++ 檔頭)。
        public var diff: String?
        public var omitted: GitDiffOmitted?

        public init(path: String, change: GitChangeKind, diff: String? = nil, omitted: GitDiffOmitted? = nil) {
            self.path = path
            self.change = change
            self.diff = diff
            self.omitted = omitted
        }

        private enum CodingKeys: String, CodingKey {
            case path
            case change
            case diff
            case omitted
        }
    }
}

extension HostServiceProtocol {
    /// binary 二進位檔(含 NUL 或不是 UTF-8);too_large 超過 x-maximum-file-size 或總量已達上限;excluded 路徑在 x-excluded-file-locations 排除清單。
    public enum GitDiffOmitted: String, Codable, Sendable, CaseIterable {
        case binary
        case tooLarge = "too_large"
        case excluded
    }
}

extension HostServiceProtocol {
    /// Send When Done 佇列(raychiutw/purrdr.host#30):主機服務的 Agent 觀察者在 Agent 從 working 變成 idle／done 時送出佇列的第一則(經 expected_session 比對)。帶 pane_id 時只回這個 pane。
    public struct QueueList: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String?

        public init(requestId: String, paneId: String? = nil) {
            self.requestId = requestId
            self.paneId = paneId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
        }
    }
}

extension HostServiceProtocol {
    /// 有排隊訊息的 pane 的佇列。
    public struct QueueListResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var queues: [PaneQueue]

        public init(requestId: String, queues: [PaneQueue]) {
            self.requestId = requestId
            self.queues = queues
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case queues
        }
    }
}

extension HostServiceProtocol {
    /// 一個 pane 的佇列，依送出順序。
    public struct PaneQueue: Codable, Sendable, Equatable {
        public var paneId: String
        public var items: [QueuedPrompt]
        public var paused: QueuePause?

        public init(paneId: String, items: [QueuedPrompt], paused: QueuePause? = nil) {
            self.paneId = paneId
            self.items = items
            self.paused = paused
        }

        private enum CodingKeys: String, CodingKey {
            case paneId = "pane_id"
            case items
            case paused
        }
    }
}

extension HostServiceProtocol {
    /// 排隊的一則訊息。
    public struct QueuedPrompt: Codable, Sendable, Equatable {
        public var itemId: String
        public var text: String
        public var expectedSession: String

        public init(itemId: String, text: String, expectedSession: String) {
            self.itemId = itemId
            self.text = text
            self.expectedSession = expectedSession
        }

        private enum CodingKeys: String, CodingKey {
            case itemId = "item_id"
            case text
            case expectedSession = "expected_session"
        }
    }
}

extension HostServiceProtocol {
    /// 佇列暫停的原因。session_changed:要送出時 pane 的 Agent session 已不是第一則的 expected_session,沒有送出;remove 或 reorder 換掉第一則後解除(add 加在後面不解除),下次 Agent 做完再試。
    public enum QueuePause: String, Codable, Sendable, CaseIterable {
        case sessionChanged = "session_changed"
    }
}

extension HostServiceProtocol {
    /// 排一則訊息到 pane 的佇列尾端;expected_session 必填(送出前比對，對象換了就不送)。每個 pane 最多 20 則(超過回 queue_full),每則最多 64 KiB(UTF-8)。佇列存在狀態資料夾，主機服務重啟後還在;稽核不記內容。
    public struct QueueAdd: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        public var text: String
        public var expectedSession: String

        public init(requestId: String, paneId: String, text: String, expectedSession: String) {
            self.requestId = requestId
            self.paneId = paneId
            self.text = text
            self.expectedSession = expectedSession
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case text
            case expectedSession = "expected_session"
        }
    }
}

extension HostServiceProtocol {
    /// 已排入佇列。
    public struct QueueAddResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var itemId: String

        public init(requestId: String, itemId: String) {
            self.requestId = requestId
            self.itemId = itemId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case itemId = "item_id"
        }
    }
}

extension HostServiceProtocol {
    /// 從佇列刪除一則;不在佇列裡回 queue_item_unknown。
    public struct QueueRemove: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        public var itemId: String

        public init(requestId: String, paneId: String, itemId: String) {
            self.requestId = requestId
            self.paneId = paneId
            self.itemId = itemId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case itemId = "item_id"
        }
    }
}

extension HostServiceProtocol {
    /// 已刪除。
    public struct QueueRemoveResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 重排佇列:item_ids 必須恰好是目前佇列的所有 item_id(換順序);否則回 queue_item_unknown。
    public struct QueueReorder: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        public var itemIds: [String]

        public init(requestId: String, paneId: String, itemIds: [String]) {
            self.requestId = requestId
            self.paneId = paneId
            self.itemIds = itemIds
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case itemIds = "item_ids"
        }
    }
}

extension HostServiceProtocol {
    /// 已重排。
    public struct QueueReorderResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 某個 pane 的佇列變了(新增、刪除、重排、送出或暫停),推給所有連線。sent_item_id:這次變更是因為這則已送出。
    public struct QueueChanged: Codable, Sendable, Equatable {
        public var queue: PaneQueue
        public var sentItemId: String?

        public init(queue: PaneQueue, sentItemId: String? = nil) {
            self.queue = queue
            self.sentItemId = sentItemId
        }

        private enum CodingKeys: String, CodingKey {
            case queue
            case sentItemId = "sent_item_id"
        }
    }
}

extension HostServiceProtocol {
    /// 一個過去的 session。
    public struct HistorySession: Codable, Sendable, Equatable {
        /// session id,可直接當 agent.start 的 resume_session。
        public var id: String
        /// 對話紀錄最後修改時間(RFC 3339 UTC)。
        public var modified: String
        /// 第一則使用者訊息，空白合併後截到 120 字;找不到時省略。
        public var summary: String?

        public init(id: String, modified: String, summary: String? = nil) {
            self.id = id
            self.modified = modified
            self.summary = summary
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case modified
            case summary
        }
    }
}

extension HostServiceProtocol {
    /// 開一條 Agent 事件串流(herdr events.subscribe)。herdr 接受後回 events.subscribe.result,之後以 events.event 推送，直到 events.ended 或 events.unsubscribe。事件只是「該重讀了」的訊號，對帳用 agents.list。
    public struct EventsSubscribe: Codable, Sendable, Equatable {
        public var requestId: String
        /// 串流識別碼(app 自訂，同一條連線內不可重複);這條串流的訊息都帶它。
        public var streamId: String
        public var subscriptions: [EventSubscription]

        public init(requestId: String, streamId: String, subscriptions: [EventSubscription]) {
            self.requestId = requestId
            self.streamId = streamId
            self.subscriptions = subscriptions
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
            case subscriptions
        }
    }
}

extension HostServiceProtocol {
    /// 一筆 herdr 事件訂閱。herdr 不認得的事件或不存在的 Pane 會讓整個訂閱被拒(herdr_error)。
    public struct EventSubscription: Codable, Sendable, Equatable {
        /// herdr 的訂閱型別，例如 pane.agent_status_changed、workspace.created。
        public var event: String
        /// pane.agent_status_changed 必填;其他型別不帶。
        public var paneId: String?

        public init(event: String, paneId: String? = nil) {
            self.event = event
            self.paneId = paneId
        }

        private enum CodingKeys: String, CodingKey {
            case event
            case paneId = "pane_id"
        }
    }
}

extension HostServiceProtocol {
    /// herdr 接受了訂閱。此後的變化才會推送;之前的要靠 agents.list 對帳。
    public struct EventsSubscribeResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var streamId: String

        public init(requestId: String, streamId: String) {
            self.requestId = requestId
            self.streamId = streamId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
        }
    }
}

extension HostServiceProtocol {
    /// herdr 推送的一個事件(沒有 request_id)。
    public struct SubscribedEvent: Codable, Sendable, Equatable {
        public var streamId: String
        /// herdr 事件的 wire 名稱，例如 pane.agent_status_changed、workspace_closed。
        public var event: String
        /// 事件指名 Pane 時才有。
        public var paneId: String?

        public init(streamId: String, event: String, paneId: String? = nil) {
            self.streamId = streamId
            self.event = event
            self.paneId = paneId
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case event
            case paneId = "pane_id"
        }
    }
}

extension HostServiceProtocol {
    /// 事件串流在主機端結束(沒有 request_id)。有 code 表示失敗;herdr 的 events_lost 是 code herdr_error 加 herdr_code events_lost,app 重新訂閱並對帳。
    public struct EventsEnded: Codable, Sendable, Equatable {
        public var streamId: String
        public var code: ErrorCode?
        /// 給開發者看的說明。
        public var message: String?
        /// code 是 herdr_error 時，herdr 原本的錯誤碼。
        public var herdrCode: String?

        public init(streamId: String, code: ErrorCode? = nil, message: String? = nil, herdrCode: String? = nil) {
            self.streamId = streamId
            self.code = code
            self.message = message
            self.herdrCode = herdrCode
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case code
            case message
            case herdrCode = "herdr_code"
        }
    }
}

extension HostServiceProtocol {
    /// 關閉一條事件串流，主機服務關掉對應的 herdr 訂閱。不認得的串流識別碼也回成功。
    public struct EventsUnsubscribe: Codable, Sendable, Equatable {
        public var requestId: String
        public var streamId: String

        public init(requestId: String, streamId: String) {
            self.requestId = requestId
            self.streamId = streamId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
        }
    }
}

extension HostServiceProtocol {
    /// 事件串流已關閉，之後不再有這條串流的訊息。
    public struct EventsUnsubscribeResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 主機取檔(raychiutw/purrdr.ios#227):查檔案狀態。只允許 herdr snapshot 目前回報的 Agent 工作目錄之下，或這條連線定位過的對話紀錄裡出現的路徑;主機服務解析 symlink 後再比對工作目錄與排除清單(x-excluded-file-locations)。唯讀，唯讀裝置也可用。
    public struct FileStat: Codable, Sendable, Equatable {
        public var requestId: String
        /// 主機上的絕對路徑(不可含 . 或 .. 段落)。
        public var path: String

        public init(requestId: String, path: String) {
            self.requestId = requestId
            self.path = path
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case path
        }
    }
}

extension HostServiceProtocol {
    /// 檔案狀態。status 是 file 時帶版本(內容的 SHA-256)與大小;too_large 只帶大小。
    public struct FileStatResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var status: FileStatus
        public var version: String?
        public var size: Int?

        public init(requestId: String, status: FileStatus, version: String? = nil, size: Int? = nil) {
            self.requestId = requestId
            self.status = status
            self.version = version
            self.size = size
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case status
            case version
            case size
        }
    }
}

extension HostServiceProtocol {
    /// file:可讀的一般檔案;missing:不存在;not_regular_file:資料夾、FIFO、裝置等;unreadable:沒有權限或讀取失敗;denied:存取規則不允許;too_large:超過 25 MiB。
    public enum FileStatus: String, Codable, Sendable, CaseIterable {
        case file
        case missing
        case notRegularFile = "not_regular_file"
        case unreadable
        case denied
        case tooLarge = "too_large"
    }
}

extension HostServiceProtocol {
    /// 依版本讀 offset 起最多 length bytes(每次最多 1 MiB)。從頭讀(offset 0)或還沒有這個檔案的快照時，主機服務先檢查存取規則、把檔案讀成這條連線的快照並比對版本;之後的分塊從快照讀，分塊之間檔案被覆寫也不會拼出兩個版本。版本不符回 file_changed。
    public struct FileRead: Codable, Sendable, Equatable {
        public var requestId: String
        public var path: String
        /// file.stat 回報的版本。
        public var version: String
        public var offset: Int
        public var length: Int

        public init(requestId: String, path: String, version: String, offset: Int, length: Int) {
            self.requestId = requestId
            self.path = path
            self.version = version
            self.offset = offset
            self.length = length
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case path
            case version
            case offset
            case length
        }
    }
}

extension HostServiceProtocol {
    /// status 是 file 時帶 offset 與 bytes(標準 base64,超過檔尾時為空);其他狀態同 file.stat,不帶內容。
    public struct FileReadResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var status: FileStatus
        /// status 是 too_large 時的大小。
        public var size: Int?
        public var offset: Int?
        public var bytes: String?

        public init(requestId: String, status: FileStatus, size: Int? = nil, offset: Int? = nil, bytes: String? = nil) {
            self.requestId = requestId
            self.status = status
            self.size = size
            self.offset = offset
            self.bytes = bytes
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case status
            case size
            case offset
            case bytes
        }
    }
}

extension HostServiceProtocol {
    /// 推播外掛代裝(raychiutw/purrdr.ios#261,0.6.0 起):查 herdr 是否已安裝推播外掛(purrdr.push)、這支裝置在這台主機是否已有推播配對(~/.purrdr/push-<device_id>/pairing)、其他已配對裝置數。唯讀，唯讀裝置也可用。
    public struct PushStatus: Codable, Sendable, Equatable {
        public var requestId: String
        /// app 的推播裝置 id(與 SSH 路徑相同):1–64 個小寫英數與 -,不能是 plugin。不合格回 invalid_message。
        public var deviceId: String

        public init(requestId: String, deviceId: String) {
            self.requestId = requestId
            self.deviceId = deviceId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case deviceId = "device_id"
        }
    }
}

extension HostServiceProtocol {
    /// 開啟這支裝置在這台主機的通知：寫入推播配對(與 SSH 路徑相同的 ~/.purrdr/push-<device_id>/pairing,已有就覆寫),外掛還沒安裝就以本機使用者身分執行 herdr plugin install raychiutw/purrdr.host/host-plugin --yes(來源固定，app 不能指定)。安裝失敗時還原成寫入前的樣子(原有的配對保留)並回 push_plugin_failed。重送一律代表「以這把 key 重新配對」(覆寫配對檔;外掛已裝就不重裝)。只改靜音請用 push.update_muted。
    public struct PushInstall: Codable, Sendable, Equatable {
        public var requestId: String
        /// app 的推播裝置 id(與 SSH 路徑相同):1–64 個小寫英數與 -,不能是 plugin。不合格回 invalid_message。
        public var deviceId: String
        public var pairing: PushPairing

        public init(requestId: String, deviceId: String, pairing: PushPairing) {
            self.requestId = requestId
            self.deviceId = deviceId
            self.pairing = pairing
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case deviceId = "device_id"
            case pairing
        }
    }
}

extension HostServiceProtocol {
    /// 關閉這支裝置在這台主機的通知：只移除這支裝置的配對資料夾;沒有其他裝置的配對、且外掛是 Purrdr 裝的(~/.purrdr/push-plugin/ 的紀錄)才執行 herdr plugin uninstall purrdr.push。使用者自己裝的外掛不動。外掛移除失敗回 push_plugin_failed(配對已移除)。
    public struct PushRemove: Codable, Sendable, Equatable {
        public var requestId: String
        /// app 的推播裝置 id(與 SSH 路徑相同):1–64 個小寫英數與 -,不能是 plugin。不合格回 invalid_message。
        public var deviceId: String

        public init(requestId: String, deviceId: String) {
            self.requestId = requestId
            self.deviceId = deviceId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case deviceId = "device_id"
        }
    }
}

extension HostServiceProtocol {
    /// 推播配對檔的內容(app 的 PushPairingFile):主機服務寫成 purrdr-push 1、endpoint=、key=、muted= 各一行。endpoint 必須是 https:// 開頭、不含空白與控制字元;key 是 64 位小寫 hex;muted 不能含控制字元。不合格回 invalid_message。
    public struct PushPairing: Codable, Sendable, Equatable {
        /// 後台 /v1/push 的網址。
        public var endpoint: String
        /// 推播配對密鑰(64 位小寫 hex);只寫進主機上的配對檔，不記進稽核紀錄。
        public var key: String
        /// 這支裝置靜音的聊天(Agent 的 session 值)。
        public var muted: [String]?

        public init(endpoint: String, key: String, muted: [String]? = nil) {
            self.endpoint = endpoint
            self.key = key
            self.muted = muted
        }

        private enum CodingKeys: String, CodingKey {
            case endpoint
            case key
            case muted
        }
    }
}

extension HostServiceProtocol {
    /// 這台主機的推播狀態。
    public struct PushStatusResult: Codable, Sendable, Equatable {
        public var requestId: String
        /// herdr 已安裝 purrdr.push(不論是誰裝的)。
        public var pluginInstalled: Bool
        /// 這支裝置在這台主機有推播配對。
        public var paired: Bool
        /// 其他已配對裝置數(不含這支;不提供其他裝置的識別資訊)。
        public var otherDevices: Int

        public init(requestId: String, pluginInstalled: Bool, paired: Bool, otherDevices: Int) {
            self.requestId = requestId
            self.pluginInstalled = pluginInstalled
            self.paired = paired
            self.otherDevices = otherDevices
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case pluginInstalled = "plugin_installed"
            case paired
            case otherDevices = "other_devices"
        }
    }
}

extension HostServiceProtocol {
    /// 開啟完成，帶完成後的推播狀態(欄位同 push.status.result)。
    public struct PushInstallResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var pluginInstalled: Bool
        public var paired: Bool
        public var otherDevices: Int

        public init(requestId: String, pluginInstalled: Bool, paired: Bool, otherDevices: Int) {
            self.requestId = requestId
            self.pluginInstalled = pluginInstalled
            self.paired = paired
            self.otherDevices = otherDevices
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case pluginInstalled = "plugin_installed"
            case paired
            case otherDevices = "other_devices"
        }
    }
}

extension HostServiceProtocol {
    /// 關閉完成，帶完成後的推播狀態(欄位同 push.status.result)。
    public struct PushRemoveResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var pluginInstalled: Bool
        public var paired: Bool
        public var otherDevices: Int

        public init(requestId: String, pluginInstalled: Bool, paired: Bool, otherDevices: Int) {
            self.requestId = requestId
            self.pluginInstalled = pluginInstalled
            self.paired = paired
            self.otherDevices = otherDevices
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case pluginInstalled = "plugin_installed"
            case paired
            case otherDevices = "other_devices"
        }
    }
}

extension HostServiceProtocol {
    /// 同步這支裝置在這台主機的靜音清單(app 不保存配對密鑰，不能重送 push.install):只以原子方式改寫配對檔的 muted 行，保留 key 與 endpoint,不呼叫 herdr。沒有配對檔回 push_not_paired;muted 含控制字元或空字串回 invalid_message。
    public struct PushUpdateMuted: Codable, Sendable, Equatable {
        public var requestId: String
        /// 同 push.install 的 device_id。
        public var deviceId: String
        /// 靜音的聊天(Agent 的 session 值),整份取代;空陣列表示取消全部靜音。
        public var muted: [String]

        public init(requestId: String, deviceId: String, muted: [String]) {
            self.requestId = requestId
            self.deviceId = deviceId
            self.muted = muted
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case deviceId = "device_id"
            case muted
        }
    }
}

extension HostServiceProtocol {
    /// 靜音已更新。不問 herdr,plugin_installed 一律是 true(要確認外掛請用 push.status)。
    public struct PushUpdateMutedResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var pluginInstalled: Bool
        public var paired: Bool
        public var otherDevices: Int

        public init(requestId: String, pluginInstalled: Bool, paired: Bool, otherDevices: Int) {
            self.requestId = requestId
            self.pluginInstalled = pluginInstalled
            self.paired = paired
            self.otherDevices = otherDevices
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case pluginInstalled = "plugin_installed"
            case paired
            case otherDevices = "other_devices"
        }
    }
}

extension HostServiceProtocol {
    /// 送一則測試通知給這支裝置(raychiutw/purrdr.host#60,0.11.0 起):讀這支裝置的推播配對，對它的 endpoint 送 {key, event: test, host_name?}(後台 raychiutw/purrdr.server#19 組固定內容的通知，不受推播種類偏好影響、不去重)。只送給這支裝置，不經過主機外掛與 herdr。沒有配對、後台回 404 或 410 都回 push_not_paired(410 時刪掉這組配對，期間重新配對的不刪);連不上或後台回其他狀態碼回 push_send_failed。
    public struct PushTest: Codable, Sendable, Equatable {
        public var requestId: String
        /// 同 push.install 的 device_id。
        public var deviceId: String
        /// app 主機清單上這台主機的名稱，轉給後台放進通知標題(「Test: <名稱> needs you」)。1–64 個字(同後台的上限)、不含控制字元，不合格回 invalid_message;沒帶時不送，後台用預設標題。
        public var hostName: String?

        public init(requestId: String, deviceId: String, hostName: String? = nil) {
            self.requestId = requestId
            self.deviceId = deviceId
            self.hostName = hostName
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case deviceId = "device_id"
            case hostName = "host_name"
        }
    }
}

extension HostServiceProtocol {
    /// 後台已接受測試通知(回 2xx)。實際送達由 APNs 決定。
    public struct PushTestResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 上傳圖片或檔案(raychiutw/purrdr.host#16):開始一次分塊上傳。主機服務在系統暫存目錄底下的上傳資料夾(x-upload-folder)建暫存檔，檔名由主機服務產生(不採用 app 給的名稱),超過 7 天的上傳檔定期刪除。size 超過 x-maximum-file-size 回 upload_too_large。中繼資料剝除在 app 端做，主機服務不解析內容。
    public struct FileUploadStart: Codable, Sendable, Equatable {
        /// 也是這次上傳的 upload_id。
        public var requestId: String
        /// 總 bytes。0 時仍要送一塊 offset 0、內容為空的 chunk,收到後才存檔並回傳路徑。
        public var size: Int
        /// 主機檔名的副檔名(不含點):1–16 個英數字元，存成小寫;沒帶時不加副檔名。不合格回 invalid_message。
        public var `extension`: String?

        public init(requestId: String, size: Int, `extension`: String? = nil) {
            self.requestId = requestId
            self.size = size
            self.`extension` = `extension`
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case size
            case `extension`
        }
    }
}

extension HostServiceProtocol {
    /// 上傳已開始，之後以 upload_id 送分塊。
    public struct FileUploadStartResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var uploadId: String

        public init(requestId: String, uploadId: String) {
            self.requestId = requestId
            self.uploadId = uploadId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case uploadId = "upload_id"
        }
    }
}

extension HostServiceProtocol {
    /// 依序送一塊內容(解碼後最多 x-maximum-file-chunk bytes,超過回 upload_too_large)。offset 必須等於已收到的 bytes,超過 size 或 upload_id 不是這條連線開始的都回 invalid_message,失敗後這次上傳作廢。收滿 size 時存成正式檔。連線結束時未完成的上傳刪掉。
    public struct FileUploadChunk: Codable, Sendable, Equatable {
        public var requestId: String
        public var uploadId: String
        public var offset: Int
        /// 標準 base64。
        public var bytes: String

        public init(requestId: String, uploadId: String, offset: Int, bytes: String) {
            self.requestId = requestId
            self.uploadId = uploadId
            self.offset = offset
            self.bytes = bytes
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case uploadId = "upload_id"
            case offset
            case bytes
        }
    }
}

extension HostServiceProtocol {
    /// 分塊已寫入。收滿 size 時帶 path:主機上的絕對路徑，app 放進 prompt。
    public struct FileUploadChunkResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var uploadId: String
        /// 目前已收到的 bytes。
        public var received: Int
        public var path: String?

        public init(requestId: String, uploadId: String, received: Int, path: String? = nil) {
            self.requestId = requestId
            self.uploadId = uploadId
            self.received = received
            self.path = path
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case uploadId = "upload_id"
            case received
            case path
        }
    }
}

extension HostServiceProtocol {
    /// 列出這台主機已配對的裝置(raychiutw/purrdr.host#19;不含已撤銷的)。唯讀，唯讀裝置也可用。
    public struct DevicesList: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 已配對的裝置，依配對先後。不含權杖或其雜湊。
    public struct DevicesListResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var devices: [PairedDevice]

        public init(requestId: String, devices: [PairedDevice]) {
            self.requestId = requestId
            self.devices = devices
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case devices
        }
    }
}

extension HostServiceProtocol {
    /// 一支已配對的裝置。時間是 RFC 3339 UTC(到秒)。
    public struct PairedDevice: Codable, Sendable, Equatable {
        public var deviceId: String
        /// 配對時 app 給的裝置名稱。
        public var name: String
        public var readOnly: Bool
        public var pairedAt: String
        /// 是發出這個請求的裝置。
        public var current: Bool

        public init(deviceId: String, name: String, readOnly: Bool, pairedAt: String, current: Bool) {
            self.deviceId = deviceId
            self.name = name
            self.readOnly = readOnly
            self.pairedAt = pairedAt
            self.current = current
        }

        private enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case name
            case readOnly = "read_only"
            case pairedAt = "paired_at"
            case current
        }
    }
}

extension HostServiceProtocol {
    /// 撤銷一支已配對的裝置：之後它的每個 WSS 訊息都以 device_token_revoked 與 close code 4401 拒絕。已撤銷的再撤銷一次也成功;不認得的 device_id 回 device_unknown;不能撤銷發出請求的這支裝置(回 invalid_message,撤銷自己用 POST /v1/revoke)。
    public struct DevicesRevoke: Codable, Sendable, Equatable {
        public var requestId: String
        /// devices.list.result 裡的 device_id。
        public var deviceId: String

        public init(requestId: String, deviceId: String) {
            self.requestId = requestId
            self.deviceId = deviceId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case deviceId = "device_id"
        }
    }
}

extension HostServiceProtocol {
    /// 已撤銷。
    public struct DevicesRevokeResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var deviceId: String

        public init(requestId: String, deviceId: String) {
            self.requestId = requestId
            self.deviceId = deviceId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case deviceId = "device_id"
        }
    }
}

extension HostServiceProtocol {
    /// 從 app 管理主機服務(raychiutw/purrdr.host#18):查已安裝版本、最新版本(問 Release 來源)、自動更新開關、上次檢查或更新的結果與退回過的版本。唯讀，唯讀裝置也可用。沒有安裝(開發中直接執行)時回 host_service_not_installed。
    public struct HostServiceStatus: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 主機服務的更新狀態(同主機上的 update --check 與 version)。
    public struct HostServiceStatusResult: Codable, Sendable, Equatable {
        public var requestId: String
        /// 安裝好的執行檔回報的版本;更新後重啟前可能比 welcome 的 host_service_version 新。
        public var installedVersion: String
        /// Release 來源的最新版本;取不到時沒有這欄，改帶 latest_error。
        public var latestVersion: String?
        /// 取不到最新版本的原因(給開發者看)。
        public var latestError: String?
        /// 最新版本比已安裝的大(只往更大的版本更新)。
        public var updateAvailable: Bool
        /// 安裝紀錄的自動更新開關。
        public var autoUpdate: Bool
        public var lastUpdate: HostServiceUpdateRecord?
        /// 上次更新後起不來、已換回舊版的版本;背景自動更新不再重試它，host_service.update 仍會再試。更新成功後清掉。
        public var rolledBack: String?

        public init(requestId: String, installedVersion: String, latestVersion: String? = nil, latestError: String? = nil, updateAvailable: Bool, autoUpdate: Bool, lastUpdate: HostServiceUpdateRecord? = nil, rolledBack: String? = nil) {
            self.requestId = requestId
            self.installedVersion = installedVersion
            self.latestVersion = latestVersion
            self.latestError = latestError
            self.updateAvailable = updateAvailable
            self.autoUpdate = autoUpdate
            self.lastUpdate = lastUpdate
            self.rolledBack = rolledBack
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case installedVersion = "installed_version"
            case latestVersion = "latest_version"
            case latestError = "latest_error"
            case updateAvailable = "update_available"
            case autoUpdate = "auto_update"
            case lastUpdate = "last_update"
            case rolledBack = "rolled_back"
        }
    }
}

extension HostServiceProtocol {
    /// 上一次檢查或更新的時間與結果(update.json)。
    public struct HostServiceUpdateRecord: Codable, Sendable, Equatable {
        /// RFC 3339(UTC,到秒)。
        public var checkedAt: String
        /// 主機上 version 顯示的同一句話，例如 updated 0.5.0 -> 0.5.1、update failed: …(給人看，不解析)。
        public var result: String

        public init(checkedAt: String, result: String) {
            self.checkedAt = checkedAt
            self.result = result
        }

        private enum CodingKeys: String, CodingKey {
            case checkedAt = "checked_at"
            case result
        }
    }
}

extension HostServiceProtocol {
    /// 立即更新：有更大的版本就以獨立程序執行安裝好的 update --yes(與主機上手動更新同一條流程：update.lock、核對 SHA256SUMS、起不來就換回),回應在重啟前送出。主機服務接著重啟、連線中斷，app 重新連線後以 welcome 的 host_service_version 確認結果，失敗退回時 host_service.status 看得到 rolled_back 與 last_update。已有更新在進行回 update_in_progress;取不到最新版本或啟動不了更新程序回 update_failed。
    public struct HostServiceUpdate: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// started:更新程序已啟動，from_version → to_version;up_to_date:已是最新，沒有更新(不重啟)。
    public struct HostServiceUpdateResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var outcome: HostServiceUpdateOutcome
        /// 已安裝的版本。
        public var fromVersion: String
        /// 最新版本(started 時是要更新到的版本)。
        public var toVersion: String

        public init(requestId: String, outcome: HostServiceUpdateOutcome, fromVersion: String, toVersion: String) {
            self.requestId = requestId
            self.outcome = outcome
            self.fromVersion = fromVersion
            self.toVersion = toVersion
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case outcome
            case fromVersion = "from_version"
            case toVersion = "to_version"
        }
    }
}

extension HostServiceProtocol {
    /// 立即更新的結果。
    public enum HostServiceUpdateOutcome: String, Codable, Sendable, CaseIterable {
        case started
        case upToDate = "up_to_date"
    }
}

extension HostServiceProtocol {
    /// 開關背景自動更新(同主機上的 auto-update on|off,改安裝紀錄的 auto_update);背景服務下一次檢查時就照新的設定。
    public struct HostServiceSetAutoUpdate: Codable, Sendable, Equatable {
        public var requestId: String
        public var enabled: Bool

        public init(requestId: String, enabled: Bool) {
            self.requestId = requestId
            self.enabled = enabled
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case enabled
        }
    }
}

extension HostServiceProtocol {
    /// 已改好，帶改完後的開關。
    public struct HostServiceSetAutoUpdateResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var autoUpdate: Bool

        public init(requestId: String, autoUpdate: Bool) {
            self.requestId = requestId
            self.autoUpdate = autoUpdate
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case autoUpdate = "auto_update"
        }
    }
}

extension HostServiceProtocol {
    /// POST /v1/pair 的本文：以配對碼換裝置權杖。QR code 的內容是 purrdr://pair?address=<HTTPS 位址>&code=<配對碼>。
    public struct PairRequest: Codable, Sendable, Equatable {
        /// 大小寫與連字號不拘，例如 K7QM-2XPA。
        public var pairingCode: String
        /// 顯示在主機裝置列表的名稱。
        public var deviceName: String

        public init(pairingCode: String, deviceName: String) {
            self.pairingCode = pairingCode
            self.deviceName = deviceName
        }

        private enum CodingKeys: String, CodingKey {
            case pairingCode = "pairing_code"
            case deviceName = "device_name"
        }
    }
}

extension HostServiceProtocol {
    /// 配對成功。device_token 只在這裡出現一次，主機只存雜湊。
    public struct PairResponse: Codable, Sendable, Equatable {
        public var deviceId: String
        public var deviceToken: String
        /// 唯讀裝置的寫入類操作會被拒絕(read_only_device)。
        public var readOnly: Bool

        public init(deviceId: String, deviceToken: String, readOnly: Bool) {
            self.deviceId = deviceId
            self.deviceToken = deviceToken
            self.readOnly = readOnly
        }

        private enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case deviceToken = "device_token"
            case readOnly = "read_only"
        }
    }
}

extension HostServiceProtocol {
    /// 請求失敗(WSS 訊息，也是配對與撤銷 HTTPS 請求失敗時的本文)。訊息本身無法解析時沒有 request_id。
    public struct ErrorMessage: Codable, Sendable, Equatable {
        public var requestId: String?
        public var code: ErrorCode
        /// 給開發者看的說明，不顯示給使用者。
        public var message: String
        /// code 是 herdr_error 時，herdr 原本的錯誤碼。
        public var herdrCode: String?
        /// code 是 protocol_version_unsupported 時，主機服務支援的協定版本。
        public var supportedProtocolVersions: [Int]?

        public init(requestId: String? = nil, code: ErrorCode, message: String, herdrCode: String? = nil, supportedProtocolVersions: [Int]? = nil) {
            self.requestId = requestId
            self.code = code
            self.message = message
            self.herdrCode = herdrCode
            self.supportedProtocolVersions = supportedProtocolVersions
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case code
            case message
            case herdrCode = "herdr_code"
            case supportedProtocolVersions = "supported_protocol_versions"
        }
    }
}

extension HostServiceProtocol {
    /// 錯誤種類。WSS 收到 device_token_invalid／device_token_revoked 後，主機服務以 close code 4401 關閉連線;HTTPS 請求回 401。transcript_not_allowed:session 不是 herdr 目前回報的，或路徑不是這條連線定位過的(或其 session 資料夾 subagents/ 底下的 .jsonl);transcript_unsupported:這種 agent 的對話紀錄主機服務還讀不了;file_changed:file.read 時檔案已不是要求的版本;push_plugin_failed:herdr plugin list／install／uninstall 失敗(message 是 herdr 的輸出);push_not_paired:push.update_muted／push.test 時這支裝置在這台主機沒有推播配對(push.test 另含後台回 404／410);push_send_failed:push.test 連不上後台或後台回其他狀態碼(message 是後台的錯誤碼，例如 subscription_required、rate_limited、apns_failed;沒有錯誤碼時是 http <狀態碼> 或連線錯誤);device_unknown:devices.revoke 的 device_id 不是這台主機配對過的裝置;upload_too_large:上傳的總大小或分塊超過 x-maximum-file-size／x-maximum-file-chunk;host_service_not_installed:主機服務不是安裝好的那份，不能從 app 管理;update_in_progress:已有另一個更新在進行;update_failed:取不到最新版本、改不了設定或啟動不了更新程序(message 是原因);pane_changed:送出前比對 expected_session／expected_screen 不符，沒有送出;cwd_not_allowed:git.status／git.diff 的 cwd 不是 herdr 目前回報的 Agent 工作目錄;not_git_repository:cwd 不在 git repo 的工作目錄裡;queue_full:這個 pane 的 Send When Done 佇列已有 20 則;queue_item_unknown:queue.remove／queue.reorder 的 item_id 不在佇列裡;其他 transcript_* 對應行為規格 §4.7 的缺席、不可讀、有歧義、已壓縮。
    public enum ErrorCode: String, Codable, Sendable, CaseIterable {
        case invalidMessage = "invalid_message"
        case handshakeRequired = "handshake_required"
        case protocolVersionUnsupported = "protocol_version_unsupported"
        case herdrUnavailable = "herdr_unavailable"
        case herdrCapabilityMissing = "herdr_capability_missing"
        case herdrError = "herdr_error"
        case deviceTokenInvalid = "device_token_invalid"
        case deviceTokenRevoked = "device_token_revoked"
        case readOnlyDevice = "read_only_device"
        case pairingCodeInvalid = "pairing_code_invalid"
        case pairingCodeExpired = "pairing_code_expired"
        case transcriptNotAllowed = "transcript_not_allowed"
        case transcriptUnsupported = "transcript_unsupported"
        case transcriptAbsent = "transcript_absent"
        case transcriptUnreadable = "transcript_unreadable"
        case transcriptAmbiguous = "transcript_ambiguous"
        case transcriptCompressed = "transcript_compressed"
        case fileChanged = "file_changed"
        case pushPluginFailed = "push_plugin_failed"
        case pushNotPaired = "push_not_paired"
        case pushSendFailed = "push_send_failed"
        case uploadTooLarge = "upload_too_large"
        case deviceUnknown = "device_unknown"
        case hostServiceNotInstalled = "host_service_not_installed"
        case updateInProgress = "update_in_progress"
        case updateFailed = "update_failed"
        case paneChanged = "pane_changed"
        case cwdNotAllowed = "cwd_not_allowed"
        case notGitRepository = "not_git_repository"
        case queueFull = "queue_full"
        case queueItemUnknown = "queue_item_unknown"
        case internalError = "internal_error"
    }
}
