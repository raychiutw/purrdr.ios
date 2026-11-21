import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrTestSupport
import Testing

/// 送出前比對(#304、raychiutw/purrdr.host#29):HTTPS 主機的送出帶 app 看到的 session(回答另帶畫面指紋),
/// 主機服務比對不符時不送、回 `pane_changed`。經真正的 WebSocket 連假的主機服務。
@Suite("HTTPS 送出前比對")
struct HTTPSSendExpectationTests {
    static let paneID = "w1:p6"
    /// 範例 Agent 列表裡 w1:p6 的 session。
    static let session = "00000000-0000-0000-0000-000000000001"
    static let agent = Agent(paneID: paneID, workspaceID: "w1", kind: "claude", status: .idle)

    private static func connection(to service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9")
    }

    private static func lastMessage(_ service: FakeHostService) throws -> [String: Any] {
        let last = try #require(service.log.messages.last)
        return try #require(try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
    }

    @Test("主機服務 0.7.0:prompt 帶 expected_session,session 相同照送")
    func promptCarriesExpectedSession() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0"))
        defer { Task { await service.stop() } }

        let outcome = await PromptDelivery(client: HerdrClient(connection: Self.connection(to: service)))
            .send("再跑一次測試", to: Self.agent, expectedSession: Self.session)

        let sent = try Self.lastMessage(service)
        #expect(sent["type"] as? String == "agent.prompt")
        #expect(sent["expected_session"] as? String == Self.session)
        #expect(sent["expected_screen"] == nil)
        #expect(outcome == .delivered)
    }

    @Test("session 已換：主機服務回 pane_changed,送出結果是 paneChanged(什麼都沒送出)")
    func changedSessionIsPaneChanged() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0", paneSessions: [Self.paneID: "another-session"]))
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))

        let outcome = await PromptDelivery(client: client).send("hi", to: Self.agent, expectedSession: Self.session)
        let slash = await PromptDelivery(client: client).send("/compact", to: Self.agent, expectedSession: Self.session)

        #expect(outcome == .paneChanged)
        #expect(slash == .paneChanged)
        await #expect(throws: HostServiceError.paneChanged) {
            try await client.prompt(target: Self.paneID, text: "hi", wait: nil, expecting: SendExpectation(session: Self.session))
        }
    }

    @Test("主機服務比 0.7.0 舊或版本未知：不帶 expected_session(舊版不認得)", arguments: ["0.6.0", nil] as [String?])
    func olderHostServiceSkipsExpectation(version: String?) async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: version))
        defer { Task { await service.stop() } }

        let outcome = await PromptDelivery(client: HerdrClient(connection: Self.connection(to: service)))
            .send("hi", to: Self.agent, expectedSession: Self.session)

        #expect(try Self.lastMessage(service)["expected_session"] == nil)
        #expect(outcome == .delivered)
    }

    @Test("回答的按鍵與文字帶 session 與畫面指紋;畫面還是看到的那個就照送")
    func answerCarriesScreenFingerprint() async throws {
        let screen = "Do you want to proceed?\n❯ 1. Yes\n  2. No\n"
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0", paneScreens: [Self.paneID: screen]))
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))
        let expectation = SendExpectation(session: Self.session, screen: SendExpectation.fingerprint(ofScreen: screen))

        try await client.sendKeys(paneID: Self.paneID, keys: ["2"], expecting: expectation)
        let keys = try Self.lastMessage(service)
        try await client.sendText(paneID: Self.paneID, text: "yes", expecting: expectation)
        let text = try Self.lastMessage(service)

        for sent in [keys, text] {
            #expect(sent["expected_session"] as? String == Self.session)
            #expect(sent["expected_screen"] as? String == SendExpectation.fingerprint(ofScreen: screen))
        }
    }

    @Test("回答時畫面已變：主機服務回 pane_changed,丟 HostServiceError.paneChanged")
    func changedScreenIsPaneChanged() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0", paneScreens: [Self.paneID: "下一題\n❯ 1. A\n"]))
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))
        let stale = SendExpectation(session: Self.session, screen: SendExpectation.fingerprint(ofScreen: "上一題\n❯ 1. Yes\n"))

        await #expect(throws: HostServiceError.paneChanged) {
            try await client.sendKeys(paneID: Self.paneID, keys: ["1"], expecting: stale)
        }
    }

    @Test("畫面指紋是畫面文字 UTF-8 的 SHA-256(小寫 hex,與主機服務同一個定義)")
    func fingerprintMatchesHostServiceDefinition() {
        #expect(SendExpectation.fingerprint(ofScreen: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("SSH 主機(沒有主機服務):herdr 請求不帶比對欄位，由 app 送前重讀 snapshot 比對")
    func sshRequestsCarryNoExpectation() async throws {
        let connection = FakeHostConnection()
        await connection.expect("agent.prompt", reply: Data(#"{"id":"purrdr:agent.prompt","result":{"type":"agent_prompted"}}"#.utf8))
        await connection.expect("pane.send_keys", reply: Data(#"{"id":"purrdr:pane.send_keys","result":{"type":"ok"}}"#.utf8))
        let client = HerdrClient(connection: connection)
        let expectation = SendExpectation(session: Self.session, screen: SendExpectation.fingerprint(ofScreen: "x"))

        _ = try await client.prompt(target: Self.paneID, text: "hi", wait: nil, expecting: expectation)
        try await client.sendKeys(paneID: Self.paneID, keys: ["1"], expecting: expectation)

        let requests = await connection.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { !$0.contains("expected_") })
    }
}
