import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// HTTPS 主機的主機服務太舊、讀不了 Pane 畫面(#303):「需要你」卡仍給通用鈕，並說明要更新主機服務才看得到選項。
@MainActor
@Suite("主機服務太舊時的畫面讀取")
struct ConversationScreenUpdateTests {
    static let bridge = HerdrCommand.bridge()

    /// 仿舊版主機服務的 HTTPS 主機：`pane.read` 一律回「需要更新主機服務」(`failsScreenReads` 為 `false` 時照常讀)。
    final class OldHostServiceConnection: ForwardingHostConnection, @unchecked Sendable {
        let base: any HostConnection
        var failsScreenReads = true

        init(base: any HostConnection) { self.base = base }

        func readPaneScreen(paneID: String, lines: Int, format: PaneReadFormat) async throws -> String {
            if failsScreenReads { throw HostServiceError.hostServiceUpdateRequired(.paneRead, installedVersion: "0.6.0") }
            return try await base.readPaneScreen(paneID: paneID, lines: lines, format: format)
        }
    }

    struct Setup {
        let host: RoutingHost
        let connection: OldHostServiceConnection
        let model: ConversationModel
    }

    static func setup() throws -> Setup {
        let shell = try LocalShellHost.temporary()
        try shell.write(ConversationModelTests.fixture, to: ConversationModelTests.transcriptPath)
        let host = RoutingHost(shell: shell)
        let connection = OldHostServiceConnection(base: SSHHostConnection(channel: host))
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(channel: host), paneID: ConversationModelTests.paneID,
            knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(), clock: TestClock().clock
        )
        return Setup(host: host, connection: connection, model: model)
    }

    static let updateMessage = HostErrorText.hostServiceMessage(.hostServiceUpdateRequired(.paneRead, installedVersion: "0.6.0"))

    @Test("需要你但主機服務太舊：給通用鈕，並說明更新主機服務")
    func blockedOnOldHostService() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.snapshot { $0["agent_status"] = "blocked" })

        await setup.model.poll()

        #expect(setup.model.prompt?.kind == .unrecognized)
        #expect(setup.model.screenUpdateRequiredMessage == Self.updateMessage)
    }

    @Test("讀畫面是其他原因失敗：不提示更新主機服務")
    func otherScreenFailureIsNotUpdatePrompt() async throws {
        let setup = try Self.setup()
        setup.connection.failsScreenReads = false
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.snapshot { $0["agent_status"] = "blocked" })
        await setup.host.bridge.expect(Self.bridge, reply: FakeReply(stdout: Data(), exitCode: 1))

        await setup.model.poll()

        #expect(setup.model.prompt?.kind == .unrecognized)
        #expect(setup.model.screenUpdateRequiredMessage == nil)
    }

    @Test("主機服務更新後讀得到畫面：提示拿掉，換成畫面上的選項")
    func updatedHostServiceClearsPrompt() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.snapshot { $0["agent_status"] = "blocked" })
        await setup.model.poll()
        #expect(setup.model.screenUpdateRequiredMessage != nil)

        setup.connection.failsScreenReads = false
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.snapshot { $0["agent_status"] = "blocked" })
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-bash"))
        await setup.model.poll()

        #expect(setup.model.screenUpdateRequiredMessage == nil)
        #expect(setup.model.prompt?.question == "Do you want to proceed?")
    }
}
