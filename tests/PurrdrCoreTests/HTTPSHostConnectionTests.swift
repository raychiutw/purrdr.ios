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
        // 計時縮成四十分之一:標準期限 20 秒到 0.5 秒就到。
        let connection = HTTPSHostConnection(
            address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9", sleep: { try await Task.sleep(for: $0 / 40) })

        await #expect(throws: HerdrError.deadlineExceeded) {
            _ = try await connection.readSnapshot()
        }
    }

    @Test("斷線後下一個請求重新撥號")
    func reconnectsAfterDrop() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))
        _ = try await client.snapshot()
        // 同步點(#324):事件串流在連線被判定斷線時結束，讀到結束才送下一個請求，不靠等一段時間。
        let events = try await client.subscribe([])

        await service.dropConnections()
        do { for try await _ in events {} } catch {}
        let snapshot = try await client.snapshot()

        #expect(snapshot.agents.count == 2)
        #expect(service.log.connections == 2)
    }

    @Test("HTTPS 還不支援的操作不送出，錯誤種類是 unsupported")
    func unsupportedOperation() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        let client = HerdrClient(connection: Self.connection(to: service))
        await #expect(throws: HostServiceError.unsupported("agent.wait")) {
            _ = try await client.waitForAgent(target: "w1:p6", until: [.working], timeout: .seconds(1))
        }
        await #expect(throws: HostServiceError.unsupported("agent.get")) { _ = try await client.agentLaunchState(target: "w1:p6") }
        await #expect(throws: HostServiceError.unsupported("integration.list")) { _ = try await client.integrations() }
        await #expect(throws: HostServiceError.unsupported("pane.report_metadata")) {
            try await client.reportPresence(paneID: "w1:p6", model: nil, seq: 1)
        }
        #expect(!service.log.messages.contains { $0.contains("wait") || $0.contains("integration") || $0.contains("report_metadata") })
    }

    @Test("唯讀裝置:寫入類操作(schema 的 x-write)被主機服務拒絕,讀取類照常(UI 測試替身的寫入清單與它一致)")
    func readOnlyDeviceRejectsExactlyTheWriteOperations() async throws {
        let service = try await FakeHostService.start(.init(
            readOnlyTokens: ["token-ok"], hostServiceVersion: "0.15.0", paneScreens: ["w1:p6": "> hi\n"]))
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)

        _ = try await connection.readSnapshot()
        _ = try await connection.readPaneScreen(paneID: "w1:p6", lines: 40, format: .text)
        _ = try await connection.listSessions(cwd: "/Users/demo/p", agent: "claude")
        let rejected: [(String, () async throws -> Void)] = [
            ("sendKeys", { try await connection.sendKeys(paneID: "w1:p6", keys: ["enter"], expecting: .none) }),
            ("sendText", { try await connection.sendText(paneID: "w1:p6", text: "hi", expecting: .none) }),
            ("sendPrompt", { _ = try await connection.sendPrompt(target: "w1:p6", text: "hi", wait: nil, expecting: .none) }),
            ("renameWorkspace", { try await connection.renameWorkspace("w1", to: "a") }),
            ("renameTab", { try await connection.renameTab("w1:t1", to: "a") }),
            ("closeTab", { try await connection.closeTab("w1:t1") }),
            ("closeWorkspace", { try await connection.closeWorkspace("w1") }),
            ("createWorktree", { _ = try await connection.createWorktree(from: "w1", branch: "b") }),
            ("createWorkspace", { _ = try await connection.createWorkspace(cwd: "/tmp", label: nil) }),
            ("createTab", { _ = try await connection.createTab(in: "w1", label: nil) }),
            ("startAgent", {
                _ = try await connection.startAgent(
                    AgentStartRequest(name: "a", kind: "claude", paneID: "w1:p1", arguments: [], timeout: .seconds(1)))
            }),
        ]
        for (name, operation) in rejected {
            await #expect(throws: HostServiceError.readOnlyDevice, "\(name)") { try await operation() }
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

        try await Self.connection(to: service).sendText(paneID: "w1:p6", text: "yes", expecting: .none)

        let sent = try Self.lastMessage(service)
        #expect(sent["type"] as? String == "pane.send_text")
        #expect(sent["pane_id"] as? String == "w1:p6")
        #expect(sent["text"] as? String == "yes")
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
