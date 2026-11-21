import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH
import Testing

/// HTTPS 主機列出過去的 session 並續接(#309,主機服務 `sessions.list`、`agent.start` 的 `resume_session`),
/// 經假主機服務 WebSocket,從 `HerdrClient` 這一端驗證。
@Suite("HTTPS 主機續接 session")
struct HTTPSSessionsTests {
    private static func client(to service: FakeHostService) -> HerdrClient {
        HerdrClient(connection: HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9"))
    }

    private static func sent(_ service: FakeHostService, type: String) throws -> [String: Any] {
        let messages = service.log.messages.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return try #require(messages.last { $0["type"] as? String == type })
    }

    @Test("列 session:送 sessions.list(cwd、agent_kind),結果有 id、修改時間與摘要")
    func listsSessions() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0"))
        defer { Task { await service.stop() } }

        let sessions = try await Self.client(to: service).listSessions(cwd: "/Users/demo/ledger", agent: "claude")

        #expect(sessions.map(\.id) == ["48b84c34-58a1-465f-94b2-370ed0699957", "0b9e6f1c-2d4a-4c8e-9f00-5a1b2c3d4e5f"])
        #expect(sessions[0].summary == "Add a daily watering reminder to README.md")
        #expect(sessions[1].summary == nil)
        #expect(sessions[0].modified != nil)
        let sent = try Self.sent(service, type: "sessions.list")
        #expect(sent["cwd"] as? String == "/Users/demo/ledger")
        #expect(sent["agent_kind"] as? String == "claude")
    }

    @Test("資料夾沒有過去的 session:回空清單")
    func emptyList() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0"))
        defer { Task { await service.stop() } }

        #expect(try await Self.client(to: service).listSessions(cwd: "/empty", agent: "codex").isEmpty)
    }

    @Test("主機服務版本不足:不送出,回「需要更新主機服務」")
    func olderHostServiceRequiresUpdate() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.6.0"))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.sessionResume, installedVersion: "0.6.0")) {
            _ = try await Self.client(to: service).listSessions(cwd: "/Users/demo/ledger", agent: "claude")
        }
        #expect(!service.log.messages.contains { $0.contains("sessions.list") })
    }

    @Test("續接啟動:agent.start 帶 resume_session;沒續接時不帶")
    func startAgentResumes() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0"))
        defer { Task { await service.stop() } }
        let client = Self.client(to: service)

        try await client.startAgent(
            name: "ledger", kind: "claude", paneID: "w4:p1", arguments: [], resumeSession: "48b84c34-58a1-465f-94b2-370ed0699957", timeout: .seconds(5))
        #expect(try Self.sent(service, type: "agent.start")["resume_session"] as? String == "48b84c34-58a1-465f-94b2-370ed0699957")

        try await client.startAgent(name: "ledger", kind: "claude", paneID: "w4:p1", arguments: [], timeout: .seconds(5))
        #expect(try Self.sent(service, type: "agent.start")["resume_session"] == nil)
    }

    @Test("唯讀裝置也能列 session(sessions.list 不是寫入類),續接啟動被拒")
    func readOnlyDevice() async throws {
        let service = try await FakeHostService.start(.init(readOnlyTokens: ["token-ok"], hostServiceVersion: "0.7.0"))
        defer { Task { await service.stop() } }
        let client = Self.client(to: service)

        #expect(try await client.listSessions(cwd: "/Users/demo/ledger", agent: "claude").count == 2)
        await #expect(throws: HostServiceError.readOnlyDevice) {
            try await client.startAgent(
                name: "ledger", kind: "claude", paneID: "w4:p1", arguments: [], resumeSession: "48b84c34-58a1-465f-94b2-370ed0699957", timeout: .seconds(5))
        }
    }
}
