import Foundation
import PurrdrCore

/// HTTPS 支援的 herdr method(method 字串只寫在這裡)。
enum HerdrMethod: String {
    case ping
    case sessionSnapshot = "session.snapshot"
    case paneSendKeys = "pane.send_keys"
    case paneSendText = "pane.send_text"
    case agentPrompt = "agent.prompt"
    case workspaceCreate = "workspace.create"
    case workspaceRename = "workspace.rename"
    case tabRename = "tab.rename"
    case workspaceClose = "workspace.close"
    /// 預留(#534):主機服務還沒有 `tab.close`(purrdr.host#91),protocol 補上前一律 `unsupported`、不送出。
    case tabClose = "tab.close"
    /// 預留(#537):主機服務還沒有 `tab.create`(purrdr.host#90),protocol 補上前一律 `unsupported`、不送出。
    case tabCreate = "tab.create"
    case worktreeCreate = "worktree.create"
    case agentStart = "agent.start"
    case paneRead = "pane.read"
    case sessionsList = "sessions.list"
    /// 事件串流，走 `herdrEvents`,不是單次請求。
    case eventsSubscribe = "events.subscribe"

    /// 這個 method 需要的主機服務功能(版本門檻);`nil` 是一開始就有的。
    var requiredFeature: HostServiceFeature? {
        switch self {
        case .workspaceCreate, .workspaceRename, .workspaceClose, .worktreeCreate, .agentStart: .workspaceOperations
        case .tabRename: .tabRename
        case .paneRead: .paneRead
        case .sessionsList: .sessionResume
        default: nil
        }
    }
}

/// herdr 單次請求換成的主機服務操作。後續票要支援新的 method,先在 schema 加訊息，
/// 再在 `HerdrMethod` 與 `init` 各加一個 case。
enum HerdrOperation {
    typealias Response = @Sendable (_ id: String?, _ reply: HostServiceProtocol.ServerMessage, _ welcome: HostServiceProtocol.Welcome) throws -> Data

    /// 握手的 herdr 資訊就是答案，不送請求。
    case ping
    /// 送出 `make` 建的訊息(拿到請求識別碼),回應由 `response` 換回 herdr 的回應行。
    case request(make: @Sendable (String) -> HostServiceProtocol.ClientMessage, response: Response)

    /// 其他 method 丟 `HostServiceError.unsupported`(不送出)。
    init(_ line: HerdrRequestLine) throws {
        guard let method = HerdrMethod(rawValue: line.method) else { throw HostServiceError.unsupported(line.method) }
        switch method {
        case .ping:
            self = .ping
        case .sessionSnapshot:
            self = .request(make: { .agentsList(.init(requestId: $0)) }) { id, reply, welcome in
                guard case .agentsListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.snapshot(id: id, version: welcome.herdr.version, result: result)
            }
        case .paneSendKeys:
            let keys = try JSONDecoder().decode(SendKeysParams.self, from: line.params)
            self = .request(make: { .paneSendKeys(.init(
                    requestId: $0, paneId: keys.paneID, keys: keys.keys, expectedSession: keys.expectedSession)) }) { id, reply, _ in
                guard case .paneSendKeysResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        case .paneSendText:
            let text = try JSONDecoder().decode(SendTextParams.self, from: line.params)
            self = .request(make: { .paneSendText(.init(
                    requestId: $0, paneId: text.paneID, text: text.text, expectedSession: text.expectedSession)) }) { id, reply, _ in
                guard case .paneSendTextResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        case .agentPrompt:
            let prompt = try JSONDecoder().decode(PromptParams.self, from: line.params)
            let wait = prompt.wait.map { wait in
                HostServiceProtocol.PromptWait(
                    until: wait.until.compactMap(HostServiceProtocol.AgentStatus.init(rawValue:)), timeoutMs: wait.timeoutMs)
            }
            self = .request(make: { .agentPrompt(.init(
                    requestId: $0, paneId: prompt.target, text: prompt.text, wait: wait, expectedSession: prompt.expectedSession)) }) { id, reply, _ in
                guard case .agentPromptResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.prompted(id: id, delivery: result.delivery)
            }
        case .workspaceCreate:
            let params = try JSONDecoder().decode(WorkspaceCreateParams.self, from: line.params)
            self = .request(make: { .workspaceCreate(.init(requestId: $0, cwd: params.cwd, label: params.label)) }) { id, reply, _ in
                guard case .workspaceCreateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.created(id: id, type: "workspace_created", workspaceID: result.workspaceId, rootPaneID: result.rootPaneId)
            }
        case .workspaceRename:
            let params = try JSONDecoder().decode(WorkspaceRenameParams.self, from: line.params)
            self = .request(make: { .workspaceRename(.init(requestId: $0, workspaceId: params.workspaceID, label: params.label)) }) { id, reply, _ in
                guard case .workspaceRenameResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        case .tabRename:
            let params = try JSONDecoder().decode(TabRenameParams.self, from: line.params)
            self = .request(make: { .tabRename(.init(requestId: $0, tabId: params.tabID, label: params.label)) }) { id, reply, _ in
                guard case .tabRenameResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        case .tabClose:
            // purrdr.host#91 補上 schema 並同步後,改成送 `tabClose` 訊息(門檻另登記 HostServiceFeature)。
            throw HostServiceError.unsupported(line.method)
        case .tabCreate:
            // purrdr.host#90 補上 schema 並同步後,改成送 `tabCreate` 訊息、組回 `tab_created`(門檻另登記 HostServiceFeature)。
            throw HostServiceError.unsupported(line.method)
        case .workspaceClose:
            let params = try JSONDecoder().decode(WorkspaceIDParams.self, from: line.params)
            self = .request(make: { .workspaceClose(.init(requestId: $0, workspaceId: params.workspaceID)) }) { id, reply, _ in
                guard case .workspaceCloseResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        case .worktreeCreate:
            let params = try JSONDecoder().decode(WorktreeCreateParams.self, from: line.params)
            self = .request(make: { .worktreeCreate(.init(requestId: $0, workspaceId: params.workspaceID, branch: params.branch)) }) { id, reply, _ in
                guard case .worktreeCreateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.created(id: id, type: "worktree_created", workspaceID: result.workspaceId, rootPaneID: result.rootPaneId)
            }
        case .agentStart:
            let params = try JSONDecoder().decode(AgentStartParams.self, from: line.params)
            // 主機服務不收任意參數：只認得 Claude Code 的權限模式。
            let permissionMode: HostServiceProtocol.ClaudePermissionMode?
            // 設定檔的啟動參數(Codex 的 `--no-daemon`,#400)主機服務不收,也不能因它拒絕整個啟動;依那個種類的設定檔整組略過
            // (只略過前綴那一組,使用者自己帶的同名參數不在其內),等主機服務支援再送。
            let launchArguments = AgentCatalog.profile(forHerdrName: params.kind).session.launchArguments
            var arguments = params.args ?? []
            if !launchArguments.isEmpty, arguments.starts(with: launchArguments) { arguments.removeFirst(launchArguments.count) }
            switch arguments {
            case []: permissionMode = nil
            case let args where args.count == 2 && args[0] == "--permission-mode":
                guard let mode = HostServiceProtocol.ClaudePermissionMode(rawValue: args[1]) else { throw HostServiceError.unsupported(line.method) }
                permissionMode = mode
            default: throw HostServiceError.unsupported(line.method)
            }
            self = .request(make: {
                .agentStart(.init(
                    requestId: $0, paneId: params.paneID, name: params.name, kind: params.kind, permissionMode: permissionMode,
                    resumeSession: params.resumeSession, timeoutMs: params.timeoutMs))
            }) { id, reply, _ in
                guard case .agentStartResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        case .paneRead:
            let params = try JSONDecoder().decode(PaneReadParams.self, from: line.params)
            guard let source = HostServiceProtocol.PaneReadSource(rawValue: params.source) else { throw HostServiceError.unsupported(line.method) }
            let format = try params.format.map { raw in
                guard let format = HostServiceProtocol.PaneReadFormat(rawValue: raw) else { throw HostServiceError.unsupported(line.method) }
                return format
            }
            self = .request(make: {
                .paneRead(.init(requestId: $0, paneId: params.paneID, source: source, format: format, lines: params.lines))
            }) { id, reply, _ in
                guard case .paneReadResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.paneRead(id: id, text: result.text)
            }
        case .sessionsList:
            let params = try JSONDecoder().decode(SessionsListParams.self, from: line.params)
            guard let kind = HostServiceProtocol.ResumableAgentKind(rawValue: params.agentKind) else { throw HostServiceError.unsupported(line.method) }
            self = .request(make: { .sessionsList(.init(requestId: $0, cwd: params.cwd, agentKind: kind)) }) { id, reply, _ in
                guard case .sessionsListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.sessionsList(id: id, sessions: result.sessions)
            }
        case .eventsSubscribe:
            throw HostServiceError.unsupported(line.method)
        }
    }

    /// 送出的訊息是否是寫入類(schema 的 `x-write`,由 codegen 產生)。
    var isWrite: Bool {
        switch self {
        case .ping: false
        case .request(let make, _): make("").isWrite
        }
    }

    /// 送出類 params 的 `expected_session`:`HerdrClient` 只在 `checksSendExpectations()` 為真時帶(#304)。
    private struct SendKeysParams: Decodable {
        var paneID: String
        var keys: [String]
        var expectedSession: String?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case keys
            case expectedSession = "expected_session"
        }
    }

    private struct SendTextParams: Decodable {
        var paneID: String
        var text: String
        var expectedSession: String?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case text
            case expectedSession = "expected_session"
        }
    }

    /// herdr `agent.prompt` 的 params(`HerdrClient` 送出的形狀)。
    private struct PromptParams: Decodable {
        var target: String
        var text: String
        var wait: Wait?
        var expectedSession: String?

        enum CodingKeys: String, CodingKey {
            case target, text, wait
            case expectedSession = "expected_session"
        }

        struct Wait: Decodable {
            var until: [String]
            var timeoutMs: Int

            enum CodingKeys: String, CodingKey {
                case until
                case timeoutMs = "timeout_ms"
            }
        }
    }

    private struct WorkspaceCreateParams: Decodable {
        var cwd: String
        var label: String?
    }

    private struct TabRenameParams: Decodable {
        var tabID: String
        var label: String

        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case label
        }
    }

    private struct WorkspaceRenameParams: Decodable {
        var workspaceID: String
        var label: String

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case label
        }
    }

    private struct WorkspaceIDParams: Decodable {
        var workspaceID: String

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
        }
    }

    private struct WorktreeCreateParams: Decodable {
        var workspaceID: String
        var branch: String

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case branch
        }
    }

    /// herdr `pane.read` 的 params(`HerdrClient` 送出的形狀;`format` 沒帶是 text)。
    private struct PaneReadParams: Decodable {
        var paneID: String
        var source: String
        var lines: Int?
        var format: String?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case source, lines, format
        }
    }

    private struct SessionsListParams: Decodable {
        var cwd: String
        var agentKind: String

        enum CodingKeys: String, CodingKey {
            case cwd
            case agentKind = "agent_kind"
        }
    }

    /// herdr `agent.start` 的 params(`HerdrClient` 送出的形狀)。
    private struct AgentStartParams: Decodable {
        var name: String
        var kind: String
        var paneID: String
        var args: [String]?
        var resumeSession: String?
        var timeoutMs: Int?

        enum CodingKeys: String, CodingKey {
            case name, kind, args
            case paneID = "pane_id"
            case resumeSession = "resume_session"
            case timeoutMs = "timeout_ms"
        }
    }
}
