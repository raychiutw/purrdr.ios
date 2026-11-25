import Foundation
import PurrdrCore

/// SSH 連線層的續接換算(#535):herdr 沒有 `sessions.list`,`agent.start` 也沒有 `resume_session`——這兩個是主機服務(HTTPS)的訊息,
/// `HerdrClient` 對兩種連線送同樣的請求,SSH 在這裡換成主機上的做法:
/// - `sessions.list` → 列清單的一次性腳本(`SessionHistoryCommand`),不經 herdr bridge;
/// - `agent.start` 帶 `resume_session` → 把續接參數接在 `args` 後面(Claude `--resume <id>`、Codex `resume <id>`,順序同主機服務:`codex --no-daemon resume <id>`)。
enum SSHResumeRequest: Equatable {
    /// 照原樣送給 herdr(不是這兩種,或沒有續接)。
    case passthrough(Data)
    /// 改寫過的 `agent.start`。
    case rewritten(Data)
    case sessionsList(requestID: String?, cwd: String, kind: String)

    /// session id:英數字與 `-`,不能以 `-` 開頭(會被 Agent 當成選項)。與主機服務(`session_history::is_safe_id`)相同。
    static func isSafeID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    private struct Envelope: Decodable {
        var id: String?
        var method: String?
    }

    private struct ListParams: Decodable {
        var cwd: String
        var agentKind: String

        enum CodingKeys: String, CodingKey {
            case cwd
            case agentKind = "agent_kind"
        }
    }

    private struct ListRequest: Decodable {
        var params: ListParams
    }

    private static func invalid(_ message: String) -> HerdrError { .herdr(code: "invalid_request", message: message) }

    init(_ request: Data) throws {
        // 只有這兩個 method 要換算;其他請求(含沒有續接的 agent.start)原封不動,不重新編碼。
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: request) else {
            self = .passthrough(request)
            return
        }
        switch envelope.method {
        case "sessions.list":
            guard let list = try? JSONDecoder().decode(ListRequest.self, from: request).params else { throw Self.invalid("sessions.list needs cwd and agent_kind") }
            guard [AgentID.claude, .codex].contains(AgentID(herdrName: list.agentKind)) else { throw Self.invalid("sessions.list supports claude and codex") }
            self = .sessionsList(requestID: envelope.id, cwd: list.cwd, kind: list.agentKind)
        case "agent.start":
            guard var object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
                  var params = object["params"] as? [String: Any], let session = params["resume_session"] as? String else {
                self = .passthrough(request)
                return
            }
            let resumeArguments: [String]
            switch (params["kind"] as? String).map(AgentID.init(herdrName:)) {
            case .claude: resumeArguments = ["--resume", session]
            case .codex: resumeArguments = ["resume", session]
            default: throw Self.invalid("resume_session needs a claude or codex agent")
            }
            guard Self.isSafeID(session) else { throw Self.invalid("resume_session needs a session id (letters, digits and -)") }
            params["resume_session"] = nil
            params["args"] = ((params["args"] as? [String]) ?? []) + resumeArguments
            object["params"] = params
            let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            self = .rewritten(encoded + [0x0A])
        default:
            self = .passthrough(request)
        }
    }

    /// `sessions.list` 的回應行(與主機服務換出來的同一個形狀,`HerdrClient.listSessions` 解析)。
    static func sessionsListResponse(requestID: String?, sessions: [ResumableSession]) throws -> Data {
        let entries: [[String: Any]] = sessions.map { session in
            var entry: [String: Any] = ["id": session.id]
            if let modified = session.modified { entry["modified"] = Date.ISO8601FormatStyle().format(modified) } else { entry["modified"] = "" }
            if let summary = session.summary { entry["summary"] = summary }
            return entry
        }
        let object: [String: Any] = ["id": requestID ?? "purrdr:sessions.list", "result": ["type": "sessions_list", "sessions": entries] as [String: Any]]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
