import Foundation
import PurrdrCore
import Testing

/// 主機服務協定(ADR-0010):`protocol/examples/` 的範例以產生的 Swift 型別編解碼後不失真。
/// 同一組範例也由主機服務的 Rust 測試(`host-service/service/tests/protocol_examples.rs`)驗證。
@Suite("主機服務協定範例")
struct HostServiceProtocolExampleTests {
    static let examplesDirectory = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "protocol/examples")

    static func examples() throws -> [(name: String, data: Data)] {
        try FileManager.default.contentsOfDirectory(at: examplesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
    }

    static func jsonObject(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    static func example(_ name: String) throws -> Data {
        try Data(contentsOf: examplesDirectory.appending(path: name))
    }

    @Test("每個協定範例以 Swift 型別編解碼後不變")
    func everyExampleRoundTrips() throws {
        let examples = try Self.examples()
        #expect(examples.count >= 8, "範例太少，路徑可能錯了")
        for (name, data) in examples {
            let reencoded: Data
            if name.hasPrefix("client.") {
                reencoded = try JSONEncoder().encode(JSONDecoder().decode(HostServiceProtocol.ClientMessage.self, from: data))
            } else {
                reencoded = try JSONEncoder().encode(JSONDecoder().decode(HostServiceProtocol.ServerMessage.self, from: data))
            }
            #expect(try Self.jsonObject(reencoded) == Self.jsonObject(data), "\(name) 編解碼後不同")
        }
    }

    @Test("握手成功帶回主機服務與 herdr 伺服器的版本")
    func welcomeCarriesVersions() throws {
        let message = try JSONDecoder().decode(HostServiceProtocol.ServerMessage.self, from: Self.example("server.welcome.json"))

        guard case .welcome(let welcome) = message else {
            Issue.record("不是 welcome:\(message)")
            return
        }
        #expect(welcome.protocolVersion == HostServiceProtocol.version)
        #expect(welcome.hostServiceVersion == "0.1.0")
        #expect(welcome.herdr.protocol == 22)
        #expect(welcome.herdr.capabilities.contains("health_check"))
    }

    @Test("Agent 列表的選填欄位缺少時是 nil")
    func agentsListResultDecodesOptionalFields() throws {
        let message = try JSONDecoder().decode(HostServiceProtocol.ServerMessage.self, from: Self.example("server.agents-list-result.json"))

        guard case .agentsListResult(let result) = message else {
            Issue.record("不是 agents.list.result:\(message)")
            return
        }
        #expect(result.agents.map(\.status) == [.idle, .unknown])
        #expect(result.agents[0].session?.value == "00000000-0000-0000-0000-000000000001")
        #expect(result.agents[1].agent == nil)
        #expect(result.workspaces.map(\.label) == ["garden-journal", "scratch"])
    }

    @Test("錯誤訊息帶錯誤碼;無法解析的訊息沒有請求識別碼")
    func errorMessageDecodesCode() throws {
        let message = try JSONDecoder().decode(HostServiceProtocol.ServerMessage.self, from: Self.example("server.error.invalid-message.json"))

        #expect(message == .errorMessage(.init(requestId: nil, code: .invalidMessage, message: "unknown message type")))
    }

    @Test("app 送出的握手請求以 type 標記訊息種類")
    func helloEncodesMessageType() throws {
        let hello = HostServiceProtocol.ClientMessage.hello(.init(requestId: "r1", protocolVersion: 1))

        let encoded = try Self.jsonObject(JSONEncoder().encode(hello))

        #expect(encoded == ["type": "hello", "request_id": "r1", "protocol_version": 1] as NSDictionary)
    }

    @Test("只有 schema 標 x-write 的訊息是寫入類操作")
    func onlyWriteMessagesAreMarkedAsWrite() throws {
        func decoded(_ name: String) throws -> HostServiceProtocol.ClientMessage {
            try JSONDecoder().decode(HostServiceProtocol.ClientMessage.self, from: Self.example(name))
        }

        #expect(try decoded("client.pane-send-keys.json").isWrite)
        #expect(try decoded("client.pane-send-text.json").isWrite)
        #expect(try decoded("client.agent-prompt.json").isWrite)
        #expect(try !decoded("client.hello.json").isWrite)
        #expect(try !decoded("client.agents-list.json").isWrite)
    }

    @Test("配對請求與回應的本文編解碼後不變")
    func pairingBodiesRoundTrip() throws {
        let request = try Self.example("http/pair-request.json")
        let response = try Self.example("http/pair-response.json")
        let failure = try Self.example("http/error.pairing-code-expired.json")

        let decodedRequest = try JSONDecoder().decode(HostServiceProtocol.PairRequest.self, from: request)
        let decodedResponse = try JSONDecoder().decode(HostServiceProtocol.PairResponse.self, from: response)
        let decodedFailure = try JSONDecoder().decode(HostServiceProtocol.ServerMessage.self, from: failure)

        #expect(decodedRequest.pairingCode == "K7QM-2XPA")
        #expect(decodedResponse.readOnly == false)
        #expect(decodedFailure == .errorMessage(.init(requestId: nil, code: .pairingCodeExpired, message: "pairing code expired")))
        #expect(try Self.jsonObject(JSONEncoder().encode(decodedRequest)) == Self.jsonObject(request))
        #expect(try Self.jsonObject(JSONEncoder().encode(decodedResponse)) == Self.jsonObject(response))
    }

    @Test("未知的訊息種類解碼失敗")
    func unknownMessageTypeFailsToDecode() {
        let data = Data(#"{"type":"exec","request_id":"r1","command":"ls"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HostServiceProtocol.ServerMessage.self, from: data)
        }
    }
}
