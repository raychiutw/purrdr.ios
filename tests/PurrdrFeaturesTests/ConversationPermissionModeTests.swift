import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Claude 權限模式膠囊(#306):從畫面讀目前模式,以 Shift+Tab 切到目標,對不上時說明並可再試。
/// 主機服務沒有專屬切換訊息,SSH 與 HTTPS 都是 `pane.send_keys` + `pane.read`。**不對任何真實 agent 送按鍵。**
@MainActor
@Suite("Claude 權限模式")
struct ConversationPermissionModeTests {
    static let bridge = HerdrCommand.bridge()

    static func screen(_ mode: AgentPermissionMode) -> FakeReply {
        let footer = switch mode {
        case .normal: "? for shortcuts"
        case .acceptEdits: "⏵⏵ accept edits on (shift+tab to cycle)"
        case .plan: "⏸ plan mode on (shift+tab to cycle)"
        case .bypassPermissions: "⏵⏵ bypass permissions on (shift+tab to cycle)"
        }
        return PaneScreens.read(text: "│ > ▌ │\n  \(footer)\n")
    }

    static func opened() async throws -> ConversationAnswerTests.Setup {
        let setup = try ConversationAnswerTests.setup(sleeper: RecordingSleeper { $0 == .milliseconds(300) })
        await setup.host.bridge.expect(bridge, reply: ConversationAnswerTests.snapshot(status: "idle"))
        await setup.model.poll()
        return setup
    }

    static func shiftTabCount(_ setup: ConversationAnswerTests.Setup) async -> Int {
        await ConversationAnswerTests.keyRequests(setup).filter { $0 == ConversationAnswerTests.keys(["shift+tab"]) }.count
    }

    @Test("讀畫面得到目前模式")
    func readsCurrentMode() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.acceptEdits))

        await setup.model.refreshPermissionMode()

        #expect(setup.model.permissionMode == .acceptEdits)
    }

    @Test("切到目標:每按一次 Shift+Tab 就讀畫面對照,到了就停")
    func switchesUntilTargetShown() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.acceptEdits))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.plan))

        await setup.model.setPermissionMode(.plan)

        #expect(await Self.shiftTabCount(setup) == 2)
        #expect(setup.model.permissionMode == .plan)
        #expect(setup.model.notice == nil)
        #expect(!setup.model.isSwitchingPermissionMode)
    }

    @Test("已經是目標模式不送任何按鍵")
    func alreadyThere() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.plan))

        await setup.model.setPermissionMode(.plan)

        #expect(await Self.shiftTabCount(setup) == 0)
    }

    @Test("點一下切到下一個模式")
    func cycleGoesToNext() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.acceptEdits))
        await setup.model.refreshPermissionMode()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.acceptEdits))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.plan))

        await setup.model.cyclePermissionMode()

        #expect(setup.model.permissionMode == .plan)
    }

    @Test("畫面一直對不上:試滿次數後說明「試了 N 次」,保留實際模式,可再試")
    func failureExplainsAndAllowsRetry() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        for _ in 0..<AgentPermissionMode.maximumSwitchAttempts {
            await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
            await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        }

        await setup.model.setPermissionMode(.bypassPermissions)

        #expect(await Self.shiftTabCount(setup) == AgentPermissionMode.maximumSwitchAttempts)
        #expect(setup.model.notice == .permissionModeFailed(attempts: AgentPermissionMode.maximumSwitchAttempts, target: .bypassPermissions))
        #expect(setup.model.permissionMode == .normal)
        #expect(!setup.model.isSwitchingPermissionMode)
        #expect(setup.model.canSwitchPermissionMode)
    }

    @Test("按鍵送不出去:提示並可再試")
    func keysFailure() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        await setup.host.bridge.expect(Self.bridge, reply: FakeReply(stdout: Data(), exitCode: 1))

        await setup.model.setPermissionMode(.plan)

        #expect(setup.model.notice == .panelKeysFailed)
        #expect(!setup.model.isSwitchingPermissionMode)
    }

    @Test("只有 Claude Code 有權限模式")
    func onlyClaude() async throws {
        let setup = try ConversationAnswerTests.setup()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "idle", kind: "codex"))
        await setup.model.poll()

        #expect(!setup.model.supportsPermissionMode)
    }
}
