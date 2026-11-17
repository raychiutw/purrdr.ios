import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 唯讀裝置(HTTPS 連線方式配對成唯讀，#60):看得到對話與「需要你」,但不能送 prompt、回答或中斷。
@MainActor
@Suite("唯讀裝置的對話")
struct ConversationReadOnlyTests {
    static let bridge = HerdrCommand.bridge()

    /// 仿 HTTPS 連線方式的唯讀裝置：讀取轉給 SSH 假主機;寫入類操作一律被主機服務拒絕。
    struct ReadOnlyHostConnection: HostConnection {
        let base: any HostConnection
        /// 握手時主機服務回報的唯讀(`false` 模擬還沒得知)。
        let reportsReadOnly: Bool

        func isReadOnlyDevice() async throws -> Bool { reportsReadOnly }

        func herdrRequest(_ request: Data, deadline: Duration) async throws -> Data {
            let method = (try? JSONSerialization.jsonObject(with: request) as? [String: Any])?["method"] as? String ?? ""
            if ["agent.prompt", "pane.send_text", "pane.send_keys"].contains(method) { throw HostServiceError.readOnlyDevice }
            return try await base.herdrRequest(request, deadline: deadline)
        }

        func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error> {
            try await base.herdrEvents(request)
        }

        func readTranscript(_ request: TranscriptRequest) async throws -> Data {
            try await base.readTranscript(request)
        }

        func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection {
            try await base.openPaneTerminal(target: target, columns: columns, rows: rows, takeover: takeover)
        }

        func disconnect() async {
            await base.disconnect()
        }
    }

    struct Setup {
        let host: RoutingHost
        let model: ConversationModel
    }

    static func setup(reportsReadOnly: Bool = true) throws -> Setup {
        let shell = try LocalShellHost.temporary()
        try shell.write(ConversationModelTests.fixture, to: ConversationModelTests.transcriptPath)
        let host = RoutingHost(shell: shell)
        let connection = ReadOnlyHostConnection(base: SSHHostConnection(channel: host), reportsReadOnly: reportsReadOnly)
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(channel: host), paneID: ConversationModelTests.paneID,
            knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(), clock: TestClock().clock
        )
        return Setup(host: host, model: model)
    }

    static func snapshot(status: String) -> FakeReply {
        ConversationModelTests.snapshot { $0["agent_status"] = status }
    }

    static func writes(_ setup: Setup) async -> [String] {
        await setup.host.bridge.executions.map(\.stdinText).filter { $0.contains("send_") || $0.contains("agent.prompt") }
    }

    @Test("主機服務回報唯讀：不能送 prompt,也不能回答「需要你」")
    func readOnlyCannotSendOrAnswer() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-bash"))

        await setup.model.poll()
        setup.model.draft = "繼續"

        #expect(setup.model.isReadOnly)
        #expect(setup.model.prompt?.question == "Do you want to proceed?")
        let option = try #require(setup.model.prompt?.options.first)
        #expect(!setup.model.canSend)
        #expect(!setup.model.canAnswer(.option(option)))
        await setup.model.send()
        await setup.model.answer(.option(option))
        #expect(await Self.writes(setup).isEmpty)
        #expect(setup.model.draft == "繼續")
    }

    @Test("主機服務回報唯讀：工作中的 agent 也不能停止")
    func readOnlyCannotStop() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))

        await setup.model.poll()

        #expect(setup.model.agentStatus == .working)
        #expect(!setup.model.canStop)
    }

    @Test("可寫入的裝置不是唯讀")
    func writableDeviceIsNotReadOnly() async throws {
        let setup = try Self.setup(reportsReadOnly: false)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))

        await setup.model.poll()
        setup.model.draft = "繼續"

        #expect(!setup.model.isReadOnly)
        #expect(setup.model.canSend)
    }

    @Test("送出時才被主機服務以唯讀拒絕：什麼都沒送出，拿掉回音、草稿放回，之後停用輸入")
    func sendRejectedAsReadOnly() async throws {
        let setup = try Self.setup(reportsReadOnly: false)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        setup.model.draft = "繼續"

        await setup.model.send()

        #expect(setup.model.isReadOnly)
        #expect(setup.model.draft == "繼續")
        #expect(!setup.model.entries.contains { if case .echo = $0 { true } else { false } })
        #expect(setup.model.notice == .readOnlyDevice)
        #expect(!setup.model.canSend)
    }

    @Test("回答時才被主機服務以唯讀拒絕：解鎖並停用回答")
    func answerRejectedAsReadOnly() async throws {
        let setup = try Self.setup(reportsReadOnly: false)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-bash"))
        await setup.model.poll()
        let option = try #require(setup.model.prompt?.options.first)

        await setup.model.answer(.option(option))

        #expect(setup.model.isReadOnly)
        #expect(setup.model.answerInFlight == nil)
        #expect(!setup.model.canAnswer(.option(option)))
    }
}
