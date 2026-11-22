import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Antigravity 聊天的唯讀資訊(#446):從畫面狀態列讀「模式 · 模型 · effort」,標題顯示非 default 的模式、輸入列顯示模型膠囊(只顯示、不能在 app 切換)。
/// 對話紀錄是 agy 1.5.14 的真實錄製(`live-1.5.14/transcript.jsonl`),畫面是真實錄製的 `agy-idle-*`。**不對任何真實 agent 送按鍵。**
@MainActor
@Suite("對話閱讀：Antigravity 狀態列")
struct ConversationAntigravityStatusTests {
    static let bridge = HerdrCommand.bridge()
    static let paneID = ConversationModelTests.paneID
    static let conversationID = "00000000-0000-4000-8000-000000000000"

    static func opened() async throws -> ConversationModelTests.Setup {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: conversationID)
        try setup.shell.write(
            Fixtures.otherAgentTranscript("antigravity/live-1.5.14/transcript.jsonl"),
            to: ".gemini/antigravity-cli/brain/\(conversationID)/.system_generated/logs/transcript.jsonl")
        await setup.host.bridge.expect(bridge, reply: OtherAgentConversationTests.snapshot(kind: "agy", session: ["kind": "id", "value": conversationID]))
        await setup.model.poll()
        return setup
    }

    @Test("讀對話紀錄:顯示對話,模型與 effort 來自最後一則回覆")
    func transcriptGivesModel() async throws {
        let setup = try await Self.opened()

        #expect(setup.model.phase == .ready)
        #expect(!setup.model.items.isEmpty)
        #expect(setup.model.modelName == "Gemini 4 Neon")
        #expect(setup.model.modelSummary == "Gemini 4 Neon · Medium")
    }

    @Test("讀畫面:plan 模式顯示在標題的徽章,模型膠囊顯示,但不能切換權限模式或模型")
    func planModeShownReadOnly() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-plan"))

        await setup.model.refreshStatusLine()

        #expect(setup.model.permissionMode == .plan)
        #expect(setup.model.header.permissionBadge?.mode == .plan)
        #expect(setup.model.showsModelCapsule)
        #expect(setup.model.supportsPermissionMode)
        #expect(setup.model.canSwitchPermissionMode)
        #expect(!setup.model.canChooseModel)
        #expect(setup.model.modelChoiceLock == .notVerified(documentedFor: "Antigravity CLI 1.5.14"))
    }

    @Test("default 模式(狀態列沒有模式那一段)是一般模式,標題沒有徽章")
    func defaultModeHasNoBadge() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-default"))

        await setup.model.refreshStatusLine()

        #expect(setup.model.permissionMode == .normal)
        #expect(setup.model.header.permissionBadge == nil)
    }

    @Test("畫面讀不出狀態列(讀不到或被蓋住)沿用上次的值")
    func unreadableKeepsLast() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-accept-edits"))
        await setup.model.refreshStatusLine()
        #expect(setup.model.permissionMode == .acceptEdits)

        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: "nothing useful here\n"))
        await setup.model.refreshStatusLine()

        #expect(setup.model.permissionMode == .acceptEdits)
    }

    @Test("Claude 與其他種類不讀狀態列:不送 pane.read")
    func otherAgentsDoNotRead() async throws {
        let setup = try ConversationModelTests.setup()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.snapshot())
        await setup.model.poll()

        await setup.model.refreshStatusLine()

        #expect(await setup.host.bridge.executions.filter { $0.stdinText.contains(#""method":"pane.read""#) }.isEmpty)
    }
}
