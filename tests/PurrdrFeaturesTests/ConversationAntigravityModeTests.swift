import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Antigravity 權限模式切換(#447):畫面是 agy 1.5.14 真實錄製的四種閒置畫面(`agy-idle-*`),輪替順序
/// auto → plan → default → accept-edits 也取自錄製的實測。送鍵的對象是假主機,**不對任何真實 agent 送按鍵**。
@MainActor
@Suite("Antigravity 權限模式切換")
struct ConversationAntigravityModeTests {
    static let bridge = HerdrCommand.bridge()

    static func opened(status: String = "idle") async throws -> ConversationAnswerTests.Setup {
        let setup = try ConversationAnswerTests.setup(sleeper: RecordingSleeper { $0 == .milliseconds(300) })
        await setup.host.bridge.expect(bridge, reply: ConversationAnswerTests.snapshot(status: status, kind: "agy", session: false))
        await setup.model.poll()
        return setup
    }

    static func expectKeyAndScreen(_ setup: ConversationAnswerTests.Setup, screen: String) async {
        await setup.host.bridge.expect(bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(bridge, reply: PaneScreens.read(screen))
    }

    static func shiftTabCount(_ setup: ConversationAnswerTests.Setup) async -> Int {
        await ConversationAnswerTests.keyRequests(setup).filter { $0 == ConversationAnswerTests.keys(["shift+tab"]) }.count
    }

    @Test("從 auto 切到 accept-edits:依錄製的輪替 auto → plan → default → accept-edits 按三次,每次讀狀態列對照")
    func switchesThroughRecordedCycle() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-auto"))
        await Self.expectKeyAndScreen(setup, screen: "agy-idle-plan")
        await Self.expectKeyAndScreen(setup, screen: "agy-idle-default")
        await Self.expectKeyAndScreen(setup, screen: "agy-idle-accept-edits")

        await setup.model.setPermissionMode(.acceptEdits)

        #expect(await Self.shiftTabCount(setup) == 3)
        #expect(setup.model.permissionMode == .acceptEdits)
        #expect(setup.model.permissionModeFailure == nil)
    }

    @Test("畫面還沒重畫(讀到的模式沒變):先再讀一次,不重複按 Shift+Tab 跳過目標")
    func staleScreenIsReReadBeforePressingAgain() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-auto"))
        await Self.expectKeyAndScreen(setup, screen: "agy-idle-auto")
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-plan"))

        await setup.model.setPermissionMode(.plan)

        #expect(await Self.shiftTabCount(setup) == 1)
        #expect(setup.model.permissionMode == .plan)
        #expect(setup.model.permissionModeFailure == nil)
    }

    @Test("已經是目標模式不送按鍵;default 模式(狀態列沒有模式那一段)就是一般模式")
    func alreadyThere() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-default"))

        await setup.model.setPermissionMode(.normal)

        #expect(await Self.shiftTabCount(setup) == 0)
    }

    @Test("選項只有 agy 輪替裡的四種(不含略過權限與不詢問),依畫面順序")
    func options() async throws {
        let setup = try await Self.opened()
        #expect(setup.model.permissionModeOptions == [.normal, .acceptEdits, .plan, .auto])
    }

    @Test("目標不在 agy 的輪替裡(略過權限)不送任何按鍵")
    func targetOutsideCycle() async throws {
        let setup = try await Self.opened()

        await setup.model.setPermissionMode(.bypassPermissions)

        #expect(await ConversationAnswerTests.keyRequests(setup).isEmpty)
        #expect(await ConversationAnswerTests.paneReads(setup) == 0)
    }

    @Test("工作中不切換(錄製只有閒置時的輪替):鎖定原因是工作中,一個鍵都不送")
    func lockedWhileWorking() async throws {
        let setup = try await Self.opened(status: "working")
        #expect(setup.model.permissionModeLock == .working)
        #expect(!setup.model.canSwitchPermissionMode)

        await setup.model.setPermissionMode(.plan)

        #expect(await ConversationAnswerTests.keyRequests(setup).isEmpty)
    }

    @Test("Claude 工作中仍可切換(不受 agy 的工作中鎖影響)")
    func claudeNotLockedWhileWorking() async throws {
        let setup = try ConversationAnswerTests.setup()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "working"))
        await setup.model.poll()
        #expect(setup.model.permissionModeLock == nil)
    }

    @Test("按鍵送不出去:說明並可再試")
    func keysFailure() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-auto"))
        await setup.host.bridge.expect(Self.bridge, reply: FakeReply(stdout: Data(), exitCode: 1))

        await setup.model.setPermissionMode(.plan)

        #expect(setup.model.permissionModeFailure == .keysFailed(target: .plan))
    }
}
