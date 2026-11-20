import Foundation
import PurrdrCore

/// herdr 單次請求換成的主機服務操作。HTTPS 支援的 herdr method 只列在這裡;
/// 後續票要支援新的 method,先在 schema 加訊息，再在 `init` 加一個 case。
enum HerdrOperation {
    typealias Response = @Sendable (_ id: String?, _ reply: HostServiceProtocol.ServerMessage, _ welcome: HostServiceProtocol.Welcome) throws -> Data

    /// 握手的 herdr 資訊就是答案，不送請求。
    case ping
    /// 送出 `make` 建的訊息(拿到請求識別碼),回應由 `response` 換回 herdr 的回應行。
    case request(make: @Sendable (String) -> HostServiceProtocol.ClientMessage, response: Response)

    /// 其他 method 丟 `HostServiceError.unsupported`(不送出)。
    init(_ line: HerdrRequestLine) throws {
        switch line.method {
        case "ping":
            self = .ping
        case "session.snapshot":
            self = .request(make: { .agentsList(.init(requestId: $0)) }) { id, reply, welcome in
                guard case .agentsListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.snapshot(id: id, version: welcome.herdr.version, result: result)
            }
        case "pane.send_keys":
            let keys = try JSONDecoder().decode(SendKeysParams.self, from: line.params)
            self = .request(make: { .paneSendKeys(.init(requestId: $0, paneId: keys.paneID, keys: keys.keys)) }) { id, reply, _ in
                guard case .paneSendKeysResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        case "pane.send_text":
            let text = try JSONDecoder().decode(SendTextParams.self, from: line.params)
            self = .request(make: { .paneSendText(.init(requestId: $0, paneId: text.paneID, text: text.text)) }) { id, reply, _ in
                guard case .paneSendTextResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        case "agent.prompt":
            let prompt = try JSONDecoder().decode(PromptParams.self, from: line.params)
            let wait = prompt.wait.map { wait in
                HostServiceProtocol.PromptWait(
                    until: wait.until.compactMap(HostServiceProtocol.AgentStatus.init(rawValue:)), timeoutMs: wait.timeoutMs)
            }
            self = .request(make: { .agentPrompt(.init(requestId: $0, paneId: prompt.target, text: prompt.text, wait: wait)) }) { id, reply, _ in
                guard case .agentPromptResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.prompted(id: id, delivery: result.delivery)
            }
        case "workspace.create":
            let params = try JSONDecoder().decode(WorkspaceCreateParams.self, from: line.params)
            self = .request(make: { .workspaceCreate(.init(requestId: $0, cwd: params.cwd, label: params.label)) }) { id, reply, _ in
                guard case .workspaceCreateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.created(id: id, type: "workspace_created", workspaceID: result.workspaceId, rootPaneID: result.rootPaneId)
            }
        case "workspace.rename":
            let params = try JSONDecoder().decode(WorkspaceRenameParams.self, from: line.params)
            self = .request(make: { .workspaceRename(.init(requestId: $0, workspaceId: params.workspaceID, label: params.label)) }) { id, reply, _ in
                guard case .workspaceRenameResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        case "workspace.close":
            let params = try JSONDecoder().decode(WorkspaceIDParams.self, from: line.params)
            self = .request(make: { .workspaceClose(.init(requestId: $0, workspaceId: params.workspaceID)) }) { id, reply, _ in
                guard case .workspaceCloseResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        case "worktree.create":
            let params = try JSONDecoder().decode(WorktreeCreateParams.self, from: line.params)
            self = .request(make: { .worktreeCreate(.init(requestId: $0, workspaceId: params.workspaceID, branch: params.branch)) }) { id, reply, _ in
                guard case .worktreeCreateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.created(id: id, type: "worktree_created", workspaceID: result.workspaceId, rootPaneID: result.rootPaneId)
            }
        case "agent.start":
            let params = try JSONDecoder().decode(AgentStartParams.self, from: line.params)
            // 主機服務不收任意參數：只認得 Claude Code 的權限模式。
            let permissionMode: HostServiceProtocol.ClaudePermissionMode?
            switch params.args ?? [] {
            case []: permissionMode = nil
            case let args where args.count == 2 && args[0] == "--permission-mode":
                guard let mode = HostServiceProtocol.ClaudePermissionMode(rawValue: args[1]) else { throw HostServiceError.unsupported(line.method) }
                permissionMode = mode
            default: throw HostServiceError.unsupported(line.method)
            }
            self = .request(make: {
                .agentStart(.init(
                    requestId: $0, paneId: params.paneID, name: params.name, kind: params.kind, permissionMode: permissionMode,
                    timeoutMs: params.timeoutMs))
            }) { id, reply, _ in
                guard case .agentStartResult = reply else { throw HostServiceError.unexpectedResponse }
                return try HerdrResponseLine.ok(id: id)
            }
        default:
            throw HostServiceError.unsupported(line.method)
        }
    }

    /// 這個 herdr method 需要的主機服務功能(版本門檻);`nil` 是一開始就有的。
    static func requiredFeature(forMethod method: String) -> HostServiceFeature? {
        switch method {
        case "workspace.create", "workspace.rename", "workspace.close", "worktree.create", "agent.start": .workspaceOperations
        default: nil
        }
    }

    /// 送出的訊息是否是寫入類(schema 的 `x-write`,由 codegen 產生)。
    var isWrite: Bool {
        switch self {
        case .ping: false
        case .request(let make, _): make("").isWrite
        }
    }

    private struct SendKeysParams: Decodable {
        var paneID: String
        var keys: [String]

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case keys
        }
    }

    private struct SendTextParams: Decodable {
        var paneID: String
        var text: String

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case text
        }
    }

    /// herdr `agent.prompt` 的 params(`HerdrClient` 送出的形狀)。
    private struct PromptParams: Decodable {
        var target: String
        var text: String
        var wait: Wait?

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

    /// herdr `agent.start` 的 params(`HerdrClient` 送出的形狀)。
    private struct AgentStartParams: Decodable {
        var name: String
        var kind: String
        var paneID: String
        var args: [String]?
        var timeoutMs: Int?

        enum CodingKeys: String, CodingKey {
            case name, kind, args
            case paneID = "pane_id"
            case timeoutMs = "timeout_ms"
        }
    }
}
