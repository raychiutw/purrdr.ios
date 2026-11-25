import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 型別化主機連線 2/3 第二批(#595):`HerdrClient` 的結構與 Agent 操作(prompt、workspace、tab、worktree、啟動 agent、續接清單…)
/// 經連線的型別化操作;HTTPS 直接對應主機服務訊息,SSH 沿用 herdr NDJSON。
@Suite("上層呼叫端改用型別化操作(第二批)")
struct TypedCallerMigration2Tests {
    static let ok = Data(#"{"id":"x","result":{"type":"ok"}}"#.utf8)

    // MARK: - HerdrClient 經 FakeHostConnection 的型別化操作

    @Test("HerdrClient 的 workspace／tab 操作經型別化操作,參數原樣交給連線")
    func structureOperations() async throws {
        let connection = FakeHostConnection()
        for operation in [FakeHostConnection.Operation.workspaceRename, .tabRename, .tabClose, .workspaceClose] {
            await connection.stub(operation)
        }
        let client = HerdrClient(connection: connection)
        try await client.renameWorkspace("w1", to: "garden")
        try await client.renameTab("w1:t1", to: "logs")
        try await client.closeTab("w1:t1")
        try await client.closeWorkspace("w1")
        #expect(await connection.typedCalls == ["renameWorkspace w1 garden", "renameTab w1:t1 logs", "closeTab w1:t1", "closeWorkspace w1"])
    }

    @Test("建立 workspace:tabLabel 用結果裡的 root tab id 補命名")
    func createWorkspaceNamesRootTab() async throws {
        let connection = FakeHostConnection()
        let created = Data(
            #"{"id":"x","result":{"type":"workspace_created","workspace":{"workspace_id":"w9"},"root_pane":{"pane_id":"w9:p1","tab_id":"w9:t1"}}}"#.utf8)
        await connection.expect(.workspaceCreate, wire: created)
        await connection.expect(.tabRename, wire: Self.ok)

        let workspace = try await HerdrClient(connection: connection).createWorkspace(cwd: "/Users/demo/p", label: "p", tabLabel: "chat")

        #expect(workspace == CreatedWorkspace(workspaceID: "w9", rootPaneID: "w9:p1"))
        #expect(await connection.typedCalls == ["createWorkspace /Users/demo/p p", "renameTab w9:t1 chat"])
    }

    @Test("prompt、啟動 agent、續接清單、等待與就緒狀態經型別化操作")
    func agentOperations() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.agentPrompt, wire: Data(#"{"id":"x","result":{"type":"agent_prompted","delivery":"written_to_pty"}}"#.utf8))
        await connection.expect(.agentStart, wire: Data(#"{"id":"x","result":{"type":"agent_started","agent":{"launch_pending":true}}}"#.utf8))
        await connection.expect(.agentLaunchState, wire: Data(#"{"id":"x","result":{"agent":{"agent_status":"idle","launch_pending":false}}}"#.utf8))
        await connection.expect(.sessionsList, wire: Data(#"{"id":"x","result":{"sessions":[{"id":"s1","modified":"2026-11-25T01:02:03Z"}]}}"#.utf8))
        await connection.expect(.agentWait, wire: Self.ok)
        let client = HerdrClient(connection: connection)

        let reply = try await client.prompt(target: "w1:p1", text: "hi", wait: nil)
        let ready = try await client.startAgent(name: "n", kind: "claude", paneID: "w1:p1", arguments: [], timeout: .seconds(5))
        let state = try await client.agentLaunchState(target: "w1:p1")
        let sessions = try await client.listSessions(cwd: "/Users/demo/p", agent: "claude")
        let waited = try await client.waitForAgent(target: "w1:p1", until: [.idle], timeout: .seconds(1))

        #expect(reply.writtenOnly)
        #expect(!ready)
        #expect(state.isReady)
        #expect(sessions.map(\.id) == ["s1"])
        #expect(waited)
        #expect(await connection.typedCalls == [
            "sendPrompt w1:p1 hi", "startAgent claude w1:p1", "agentLaunchState w1:p1", "listSessions /Users/demo/p claude", "waitForAgent w1:p1",
        ])
    }

    @Test("ping、整合清單與在場回報經型別化操作")
    func miscOperations() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.ping, wire: Data(#"{"id":"x","result":{"version":"0.9.5","protocol":1}}"#.utf8))
        await connection.expect(.integrations, wire: Data(#"{"id":"x","result":{"integrations":[]}}"#.utf8))
        await connection.expect(.reportPresence, wire: Self.ok)
        let client = HerdrClient(connection: connection)

        #expect(try await client.ping() == "0.9.5")
        #expect(try await client.integrations().isEmpty)
        try await client.reportPresence(paneID: "w1:p1", model: nil, seq: 7)
        #expect(await connection.typedCalls == ["herdrVersion", "listIntegrations", "reportPresence w1:p1 - 7"])
    }

    @Test("HerdrClient 訂閱事件經 subscribeToEvents,第一項是 subscriptionStarted")
    func subscribeEvents() async throws {
        let connection = FakeHostConnection()
        await connection.expectSubscription(wire: Fixtures.data("events.subscribe.started.ndjson"))

        let events = try await HerdrClient(connection: connection).subscribe([.init(.workspaceCreated)])
        var iterator = events.makeAsyncIterator()

        #expect(try await iterator.next() == .subscriptionStarted)
        #expect(await connection.typedCalls == ["subscribeToEvents 1"])
    }

    // MARK: - HTTPS 直接對應主機服務訊息

    private static func connection(to service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9")
    }

    @Test("HTTPS 沒有的操作(整合清單、在場回報、等待、就緒狀態)直接丟 unsupported,不送出")
    func httpsUnsupportedOperations() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.15.0"))
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)

        await #expect(throws: HostServiceError.unsupported("integration.list")) { _ = try await connection.listIntegrations() }
        await #expect(throws: HostServiceError.unsupported("pane.report_metadata")) {
            try await connection.reportPresence(paneID: "w1:p1", model: nil, seq: 1)
        }
        await #expect(throws: HostServiceError.unsupported("agent.get")) { _ = try await connection.agentLaunchState(target: "w1:p1") }
        await #expect(throws: HostServiceError.unsupported("agent.wait")) {
            _ = try await connection.waitForAgent(target: "w1:p1", until: [.idle], timeout: .seconds(1))
        }
        #expect(!service.log.messages.contains { $0.contains("integration.list") || $0.contains("agent.get") })
    }

    @Test("HTTPS 事件訂閱:直接送出 HerdrEvent(先 subscriptionStarted,再主機推的事件),不經 herdr 事件行")
    func httpsSubscribeToEvents() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.15.0"))
        defer { Task { await service.stop() } }

        let events = try await Self.connection(to: service).subscribeToEvents([.agentStatusChanged(paneID: "w1:p6")])
        service.pushEvent("pane_agent_status_changed", paneID: "w1:p6")
        var iterator = events.makeAsyncIterator()

        #expect(try await iterator.next() == .subscriptionStarted)
        #expect(try await iterator.next() == .event(name: "pane_agent_status_changed", paneID: "w1:p6"))
    }

    @Test("HTTPS 建立 workspace:回 workspace 與 root pane,沒有 root tab id(呼叫端略過 tab 命名)")
    func httpsCreateWorkspaceHasNoRootTab() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.15.0"))
        defer { Task { await service.stop() } }

        let created = try await Self.connection(to: service).createWorkspace(cwd: "/Users/demo/p", label: nil)

        #expect(created == NewWorkspace(workspace: CreatedWorkspace(workspaceID: "w1", rootPaneID: "w1:p1"), rootTabID: nil))
    }

    @Test("HTTPS 送 prompt:等待帶 working／blocked;比對 session 在主機會比對時帶")
    func httpsPromptWaitAndExpectation() async throws {
        let service = try await FakeHostService.start(.init(promptDelivery: "written_to_pty", hostServiceVersion: "0.7.0", paneSessions: ["w1:p1": "s-1"]))
        defer { Task { await service.stop() } }

        let reply = try await Self.connection(to: service).sendPrompt(
            target: "w1:p1", text: "hi", wait: .seconds(3), expecting: SendExpectation(session: "s-1"))

        #expect(reply.writtenOnly)
        let messages = service.log.messages.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let sent = try #require(messages.last { $0["type"] as? String == "agent.prompt" })
        #expect(sent["pane_id"] as? String == "w1:p1")
        #expect(sent["expected_session"] as? String == "s-1")
        let wait = try #require(sent["wait"] as? [String: Any])
        #expect(wait["until"] as? [String] == ["working", "blocked"])
        #expect(wait["timeout_ms"] as? Int == 3000)
    }

    @Test("HTTPS 續接清單:未知的 agent 種類在送出前丟 unsupported;已知種類換成 Date 與摘要")
    func httpsListSessions() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.15.0"))
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)

        await #expect(throws: HostServiceError.unsupported("sessions.list")) { _ = try await connection.listSessions(cwd: "/p", agent: "gemini") }
        let sessions = try await connection.listSessions(cwd: "/Users/demo/p", agent: "claude")
        #expect(!sessions.isEmpty)
        #expect(sessions.allSatisfy { $0.modified != nil })
    }

    // MARK: - SSH 沿用 herdr NDJSON

    @Test("SSH 的型別化 prompt:一行 agent.prompt(不帶比對欄位),回應換成 PromptReply")
    func sshPrompt() async throws {
        let host = FakeHost()
        let reply = FakeReply(
            stdout: Data(#"{"id":"purrdr:agent.prompt","result":{"type":"agent_prompted","delivery":"written_to_pty"}}"#.utf8 + [0x0A]),
            trigger: .afterStdinLine)
        await host.expect(TypedHostConnectionTests.bridgeCommand, reply: reply)

        let result = try await SSHHostConnection(channel: host).sendPrompt(
            target: "w1:p1", text: "hi", wait: nil, expecting: SendExpectation(session: "s"))

        #expect(result.writtenOnly)
        let stdin = try #require(await host.executions.first?.stdinText)
        #expect(stdin.contains(#""method":"agent.prompt""#) && !stdin.contains("expected_session"))
    }
}
