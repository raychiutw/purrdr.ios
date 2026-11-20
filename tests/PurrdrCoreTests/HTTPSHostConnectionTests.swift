import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 連線方式的主機連線(ADR-0010):經真正的 WebSocket(URLSession)連假的主機服務，從 `HerdrClient` 這一端驗證。
@Suite("HTTPS 主機連線")
struct HTTPSHostConnectionTests {
    private static func connection(to service: FakeHostService, token: String? = "token-ok") -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { token }, appVersion: "9.9.9")
    }

    @Test("連線時帶裝置權杖，先握手再取 Agent 列表;Agent 列表與 SSH 路線看到的欄位相同")
    func agentListOverHostService() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        let snapshot = try await HerdrClient(connection: Self.connection(to: service)).snapshot()

        #expect(service.log.authorizations == ["Bearer token-ok"])
        let messages = service.log.messages.map { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(messages.first??["type"] as? String == "hello")
        #expect(messages.first??["protocol_version"] as? Int == HostServiceProtocol.version)
        #expect(messages.last??["type"] as? String == "agents.list")
        #expect(snapshot.version == "0.9.5")
        #expect(snapshot.agents.map(\.paneID) == ["w1:p6", "w2:p1"])
        let first = try #require(snapshot.agents.first)
        #expect(first.kind == "claude")
        #expect(first.status == .idle)
        #expect(first.workspaceLabel == "garden-journal")
        #expect(first.terminalTitle == "整理植物照片的標籤")
        #expect(first.cwd == "/Users/demo/Projects/garden-journal")
        #expect(first.session == AgentSessionReference(kind: "id", value: "00000000-0000-0000-0000-000000000001"))
        #expect(snapshot.agents.last?.status == .unknown)
    }

    @Test("同一條連線處理後續請求：只握手一次")
    func reusesOneConnection() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))

        _ = try await client.snapshot()
        _ = try await client.snapshot()
        let version = try await client.ping()

        #expect(service.log.connections == 1)
        #expect(service.log.messages.filter { $0.contains(#""type":"hello""#) }.count == 1)
        #expect(version == "0.9.5")
    }

    @Test("按鍵送到主機服務的 pane.send_keys")
    func sendKeys() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        try await HerdrClient(connection: Self.connection(to: service)).sendKeys(paneID: "w1:p6", keys: ["down", "enter"])

        let sent = try #require(service.log.messages.last.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(sent["type"] as? String == "pane.send_keys")
        #expect(sent["pane_id"] as? String == "w1:p6")
        #expect(sent["keys"] as? [String] == ["down", "enter"])
    }

    @Test("唯讀裝置的寫入被拒絕，錯誤種類是 readOnlyDevice")
    func readOnlyDevice() async throws {
        let service = try await FakeHostService.start(.init(readOnlyTokens: ["token-ok"]))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.readOnlyDevice) {
            try await HerdrClient(connection: Self.connection(to: service)).sendKeys(paneID: "w1:p6", keys: ["enter"])
        }
    }

    @Test(
        "權杖無效或已撤銷：以明確的錯誤種類失敗，之後不再撥號(不會無限重連)",
        arguments: [
            (FakeHostService.Settings(validTokens: []), HostServiceError.deviceTokenInvalid),
            (FakeHostService.Settings(validTokens: [], revokedTokens: ["token-ok"]), HostServiceError.deviceTokenRevoked),
        ])
    func rejectedTokenStopsReconnecting(settings: FakeHostService.Settings, expected: HostServiceError) async throws {
        let service = try await FakeHostService.start(settings)
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)
        let client = HerdrClient(connection: connection)

        await #expect(throws: expected) { try await client.snapshot() }
        await connection.disconnect()
        await #expect(throws: expected) { try await client.snapshot() }
        await #expect(throws: expected) { try await client.ping() }

        #expect(service.log.connections == 1)
    }

    @Test("連線中被撤銷：下一個請求以 deviceTokenRevoked 失敗")
    func revokedWhileConnected() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))
        _ = try await client.snapshot()

        service.revoke("token-ok")

        await #expect(throws: HostServiceError.deviceTokenRevoked) { try await client.snapshot() }
        await #expect(throws: HostServiceError.deviceTokenRevoked) { try await client.snapshot() }
        #expect(service.log.connections == 1)
    }

    @Test("重新配對換了權杖後可以再連")
    func newTokenAfterRejection() async throws {
        let service = try await FakeHostService.start(.init(validTokens: ["token-new"]))
        defer { Task { await service.stop() } }
        let stored = TokenBox("token-old")
        let client = HerdrClient(connection: HTTPSHostConnection(address: service.address, deviceToken: { stored.value }))
        await #expect(throws: HostServiceError.deviceTokenInvalid) { try await client.snapshot() }

        stored.value = "token-new"
        let snapshot = try await client.snapshot()

        #expect(snapshot.agents.count == 2)
        #expect(service.log.authorizations == ["Bearer token-old", "Bearer token-new"])
    }

    @Test("這支裝置沒有權杖：不撥號，錯誤種類是 notPaired")
    func notPaired() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.notPaired) {
            try await HerdrClient(connection: Self.connection(to: service, token: nil)).snapshot()
        }
        #expect(service.log.connections == 0)
    }

    @Test("協定版本不相容：錯誤帶主機服務支援的版本")
    func protocolVersionUnsupported() async throws {
        let service = try await FakeHostService.start(.init(supportedProtocolVersions: [99]))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.protocolVersionUnsupported(supported: [99])) {
            try await HerdrClient(connection: Self.connection(to: service)).snapshot()
        }
    }

    @Test(
        "主機服務的錯誤碼對應到使用者可見的錯誤種類;herdr 自己的錯誤保留 herdr 的碼",
        arguments: [
            (FakeHostService.AgentsReply.error(code: "herdr_unavailable"), HostServiceError.herdrUnavailable as any Error),
            (.error(code: "herdr_capability_missing"), HostServiceError.herdrCapabilityMissing),
            (.error(code: "herdr_error", message: "pane w9:pZ not found", herdrCode: "pane_not_found"),
             HerdrError.herdr(code: "pane_not_found", message: "pane w9:pZ not found")),
        ])
    func errorCodes(reply: FakeHostService.AgentsReply, expected: any Error) async throws {
        let service = try await FakeHostService.start(.init(agentsReply: reply))
        defer { Task { await service.stop() } }

        let error = try #require(await #expect(throws: (any Error).self) { try await HerdrClient(connection: Self.connection(to: service)).snapshot() })

        #expect(String(describing: error) == String(describing: expected))
    }

    @Test("主機服務不回應：期限到丟 deadlineExceeded")
    func deadline() async throws {
        let service = try await FakeHostService.start(.init(agentsReply: .silent))
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)
        let request = Data(#"{"id":"purrdr:session.snapshot","method":"session.snapshot","params":{}}"#.utf8) + [0x0A]

        await #expect(throws: HerdrError.deadlineExceeded) {
            try await connection.herdrRequest(request, deadline: .milliseconds(500))
        }
    }

    @Test("斷線後下一個請求重新撥號")
    func reconnectsAfterDrop() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))
        _ = try await client.snapshot()

        await service.dropConnections()
        try await Task.sleep(for: .milliseconds(200))
        let snapshot = try await client.snapshot()

        #expect(snapshot.agents.count == 2)
        #expect(service.log.connections == 2)
    }

    @Test("HTTPS 還不支援的操作不送出，錯誤種類是 unsupported")
    func unsupportedOperation() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.unsupported("agent.wait")) {
            _ = try await HerdrClient(connection: Self.connection(to: service)).waitForAgent(target: "w1:p6", until: [.working], timeout: .seconds(1))
        }
        #expect(!service.log.messages.contains { $0.contains("wait") })
    }

    @Test(
        "herdr 請求是否寫入類照協定的 x-write 判斷(UI 測試替身與主機服務用同一個來源)",
        arguments: [
            (#"{"id":"1","method":"agent.prompt","params":{"target":"w1:p1","text":"hi"}}"#, true),
            (#"{"id":"1","method":"pane.send_text","params":{"pane_id":"w1:p1","text":"hi"}}"#, true),
            (#"{"id":"1","method":"pane.send_keys","params":{"pane_id":"w1:p1","keys":["Enter"]}}"#, true),
            (#"{"id":"1","method":"session.snapshot","params":{}}"#, false),
            (#"{"id":"1","method":"ping"}"#, false),
        ])
    func writeRequestsFollowSchema(request: String, isWrite: Bool) throws {
        #expect(try HTTPSHostConnection.isWriteRequest(Data(request.utf8)) == isWrite)
    }

    @Test("不支援的 herdr 請求問不出是否寫入類：錯誤種類是 unsupported")
    func unsupportedRequestHasNoWriteKind() {
        #expect(throws: HostServiceError.unsupported("agent.wait")) {
            try HTTPSHostConnection.isWriteRequest(Data(#"{"id":"1","method":"agent.wait","params":{}}"#.utf8))
        }
    }

    // MARK: - 送 prompt、文字與按鍵(#60)

    private static func lastMessage(_ service: FakeHostService) throws -> [String: Any] {
        try #require(service.log.messages.last.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
    }

    @Test("prompt 送到主機服務的 agent.prompt,帶 pane、文字與等待")
    func promptGoesToAgentPrompt() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        let reply = try await HerdrClient(connection: Self.connection(to: service)).prompt(target: "w1:p6", text: "再跑一次測試", wait: .seconds(8))

        let sent = try Self.lastMessage(service)
        #expect(sent["type"] as? String == "agent.prompt")
        #expect(sent["pane_id"] as? String == "w1:p6")
        #expect(sent["text"] as? String == "再跑一次測試")
        let wait = try #require(sent["wait"] as? [String: Any])
        #expect(wait["until"] as? [String] == ["working", "blocked"])
        #expect(wait["timeout_ms"] as? Int == 8000)
        #expect(reply == PromptReply(writtenOnly: false))
    }

    @Test("slash 指令的 prompt 不帶等待")
    func promptWithoutWait() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        _ = try await HerdrClient(connection: Self.connection(to: service)).prompt(target: "w1:p6", text: "/compact", wait: nil)

        #expect(try Self.lastMessage(service)["wait"] == nil)
    }

    @Test("主機只回報寫進終端機時，prompt 結果與 SSH 路線一樣是 writtenOnly")
    func promptWrittenOnly() async throws {
        let service = try await FakeHostService.start(.init(promptDelivery: "written_to_pty"))
        defer { Task { await service.stop() } }

        let reply = try await HerdrClient(connection: Self.connection(to: service)).prompt(target: "w1:p6", text: "hi", wait: .seconds(8))

        #expect(reply == PromptReply(writtenOnly: true))
    }

    @Test("agent 在等回答：herdr 的 agent_blocked 原樣回報，送出結果是 needsAnswer")
    func promptToBlockedAgent() async throws {
        let service = try await FakeHostService.start(.init(promptHerdrError: "agent_blocked"))
        defer { Task { await service.stop() } }
        let agent = Agent(paneID: "w1:p6", workspaceID: "w1", kind: "claude", status: .blocked)

        let outcome = await PromptDelivery(client: HerdrClient(connection: Self.connection(to: service))).send("hi", to: agent)

        #expect(outcome == .needsAnswer)
    }

    @Test("文字送到主機服務的 pane.send_text")
    func sendTextGoesToPaneSendText() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let request = Data(#"{"id":"purrdr:pane.send_text","method":"pane.send_text","params":{"pane_id":"w1:p6","text":"yes"}}"#.utf8)

        let reply = try await Self.connection(to: service).herdrRequest(request, deadline: .seconds(20))

        let sent = try Self.lastMessage(service)
        #expect(sent["type"] as? String == "pane.send_text")
        #expect(sent["pane_id"] as? String == "w1:p6")
        #expect(sent["text"] as? String == "yes")
        let envelope = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(envelope["id"] as? String == "purrdr:pane.send_text")
        #expect((envelope["result"] as? [String: Any])?["type"] as? String == "ok")
    }

    @Test("唯讀裝置：連線回報唯讀;送 prompt 什麼都沒送出，結果是 readOnlyDevice")
    func readOnlyDevicePrompt() async throws {
        let service = try await FakeHostService.start(.init(readOnlyTokens: ["token-ok"]))
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))
        let agent = Agent(paneID: "w1:p6", workspaceID: "w1", kind: "claude", status: .idle)

        let readOnly = try await client.isReadOnlyDevice()
        let outcome = await PromptDelivery(client: client).send("hi", to: agent)

        #expect(readOnly)
        #expect(outcome == .readOnlyDevice)
    }

    @Test("可寫入的裝置：連線回報不是唯讀")
    func writableDevice() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        #expect(try await HerdrClient(connection: Self.connection(to: service)).isReadOnlyDevice() == false)
    }

    @Test("連線回報主機服務的版本(welcome 的 host_service_version,#198)")
    func reportsHostServiceVersion() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.0.9"))
        defer { Task { await service.stop() } }

        #expect(try await Self.connection(to: service).hostServiceVersion() == "0.0.9")
    }

    @Test("主機服務版本不足：回「需要更新主機服務」的專屬錯誤，帶功能與已安裝的版本")
    func olderHostServiceRequiresUpdate() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.3.0"))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.fileFetch, installedVersion: "0.3.0")) {
            try await Self.connection(to: service).requireHostService(.fileFetch)
        }
    }

    @Test("主機服務版本達到門檻：功能可用")
    func currentHostServiceProvidesFeature() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.4.0"))
        defer { Task { await service.stop() } }

        try await Self.connection(to: service).requireHostService(.fileFetch)
    }

    @Test("Agent 事件串流：先回 ack,連線斷了以 connectionLost 結束(上層據此重連對帳)")
    func eventStreamEndsWithConnection() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))
        let events = try await client.subscribe([])
        var iterator = events.makeAsyncIterator()

        #expect(try await iterator.next() == .subscriptionStarted)
        await service.dropConnections()

        await #expect(throws: HostServiceError.connectionLost) { _ = try await iterator.next() }
    }
}

/// 測試裡可以換掉的權杖。
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ value: String?) {
        stored = value
    }

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
