import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 聊天面板(#380、#618):面板的權限選項何時停用與原因。
@MainActor
@Suite("聊天面板權限選項")
struct ConversationTitlePanelTests {
    static let bridge = HerdrCommand.bridge()

    @Test("Agent 在等使用者:權限模式切換停用,原因是等你回覆(避免 Shift+Tab 變成核准)")
    func blockedDisablesModeSwitch() async throws {
        // 先在閒置時讀到模式(可切換),之後 Agent 轉成等使用者回覆。
        let setup = try await ConversationPermissionModeTests.opened()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationPermissionModeTests.screen(.normal))
        await setup.model.refreshPermissionMode()
        #expect(setup.model.canSwitchPermissionMode)

        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-bash"))
        await setup.model.poll()

        #expect(setup.model.permissionMode == .normal)
        #expect(!setup.model.canSwitchPermissionMode)
        #expect(setup.model.permissionModeLock == .waitingForYou)
    }

    @Test("閒置的 Claude:切換可用、沒有停用原因")
    func idleAllowsModeSwitch() async throws {
        let setup = try await ConversationPermissionModeTests.opened()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationPermissionModeTests.screen(.normal))
        await setup.model.refreshPermissionMode()

        #expect(setup.model.canSwitchPermissionMode)
        #expect(setup.model.permissionModeLock == nil)
    }

    @Test("唯讀裝置:切換停用,原因是唯讀")
    func readOnlyDisablesModeSwitch() async throws {
        let setup = try ConversationReadOnlyTests.setup()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationReadOnlyTests.snapshot(status: "idle"))
        await setup.model.poll()

        #expect(setup.model.isReadOnly)
        #expect(!setup.model.canSwitchPermissionMode)
        #expect(setup.model.permissionModeLock == .readOnlyDevice)
    }

    @Test("連線中斷是離線狀態,不混進 Agent 狀態")
    func offlineIsSeparateFromAgentStatus() {
        let header = ConversationHeader(title: "ledger", status: .offline, segments: ["studio"])
        #expect(header.agentStatus == nil)
        #expect(ConversationHeader(title: "ledger", status: .needsYou, segments: []).agentStatus == .blocked)
    }
}
