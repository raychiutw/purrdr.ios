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
        default:
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
}
