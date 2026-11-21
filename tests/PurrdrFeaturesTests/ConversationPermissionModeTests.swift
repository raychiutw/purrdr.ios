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

    @Test("畫面一直對不上:試滿次數後說明「試了 N 次」,保留實際模式,可再試")
    func failureExplainsAndAllowsRetry() async throws {
        // 目標是 Plan:畫面一直停在 Normal(沒有切換成功),不是輪替一圈。
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        for _ in 0..<AgentPermissionMode.maximumSwitchAttempts {
            await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
            await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        }

        await setup.model.setPermissionMode(.plan)

        #expect(await Self.shiftTabCount(setup) == AgentPermissionMode.maximumSwitchAttempts)
        #expect(setup.model.permissionModeFailure == .notReached(attempts: AgentPermissionMode.maximumSwitchAttempts, target: .plan))
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

        #expect(setup.model.permissionModeFailure == .keysFailed(target: .plan))
        #expect(!setup.model.isSwitchingPermissionMode)
    }

    @Test("只有 Claude Code 有權限模式")
    func onlyClaude() async throws {
        let setup = try ConversationAnswerTests.setup()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "idle", kind: "codex"))
        await setup.model.poll()

        #expect(!setup.model.supportsPermissionMode)
    }

    @Test("主機沒開略過權限:輪替一圈回到起點就停,說明主機沒開、不連按")
    func bypassUnavailableStopsAfterOneCycle() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        for shown in [AgentPermissionMode.acceptEdits, .plan, .normal] {
            await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
            await setup.host.bridge.expect(Self.bridge, reply: Self.screen(shown))
        }

        await setup.model.setPermissionMode(.bypassPermissions)

        #expect(await Self.shiftTabCount(setup) == 3)
        #expect(setup.model.permissionModeFailure == .bypassUnavailable)
        #expect(setup.model.permissionMode == .normal)
        #expect(setup.model.canSwitchPermissionMode)
    }

    @Test("再試一次:對上次失敗的目標重來,成功後清掉失敗")
    func retryRepeatsFailedTarget() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        await setup.host.bridge.expect(Self.bridge, reply: FakeReply(stdout: Data(), exitCode: 1))
        await setup.model.setPermissionMode(.acceptEdits)
        #expect(setup.model.permissionModeFailure == .keysFailed(target: .acceptEdits))
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.acceptEdits))

        await setup.model.retryPermissionMode()

        #expect(setup.model.permissionMode == .acceptEdits)
        #expect(setup.model.permissionModeFailure == nil)
    }

    @Test("切換中離開聊天(取消):不再讀畫面、不當成失敗")
    func cancellationStopsSwitching() async throws {
        let sleeper = RecordingSleeper()
        let setup = try ConversationAnswerTests.setup(sleeper: sleeper)
        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "idle"))
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        let task = Task { await setup.model.setPermissionMode(.plan) }
        while await !sleeper.requested.contains(.milliseconds(300)) { await Task.yield() }

        task.cancel()
        await task.value

        #expect(await Self.shiftTabCount(setup) == 1)
        #expect(setup.model.permissionModeFailure == nil)
        #expect(!setup.model.isSwitchingPermissionMode)
    }
}
