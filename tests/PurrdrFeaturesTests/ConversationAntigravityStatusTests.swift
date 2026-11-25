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

    static func opened(links: ConversationModel.HostLinks = .init()) async throws -> ConversationModelTests.Setup {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: conversationID, links: links)
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

    @Test("讀畫面:plan 模式讀得到,模型膠囊顯示,但不能切換權限模式或模型")
    func planModeShownReadOnly() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-plan"))

        await setup.model.refreshStatusLine()

        #expect(setup.model.permissionMode == .plan)
        #expect(setup.model.showsModelCapsule)
        #expect(setup.model.supportsPermissionMode)
        #expect(setup.model.canSwitchPermissionMode)
        #expect(!setup.model.canChooseModel)
        #expect(setup.model.modelChoiceLock == .notVerified(documentedFor: "Antigravity CLI 1.5.14"))
    }

    @Test("default 模式(狀態列沒有模式那一段)是一般模式")
    func defaultModeHasNoBadge() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-default"))

        await setup.model.refreshStatusLine()

        #expect(setup.model.permissionMode == .normal)
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

    // MARK: - statusline 包裝(#448):裝了優先用

    /// 把真實錄製的 statusline 輸入包成包裝腳本存的 session 檔,再解析成狀態。
    static func status(_ name: String, contextPercent: Double? = nil) throws -> ClaudeSessionStatus {
        var input = try #require(try JSONSerialization.jsonObject(with: Fixtures.otherAgentTranscript("antigravity/live-1.5.14/\(name).json")) as? [String: Any])
        if let contextPercent { input["context_window"] = ["used_percentage": contextPercent, "context_window_size": 1_048_576] }
        let file = try JSONSerialization.data(withJSONObject: [
            "captured_at": Date().timeIntervalSince1970, "session_id": conversationID, "status_line_input": input,
        ] as [String: Any])
        return try #require(ClaudeSessionStatus(sessionFile: file))
    }

    static func opened(statusFile name: String, contextPercent: Double? = nil) async throws -> ConversationModelTests.Setup {
        let reader = ConversationSessionStatusTests.Reader([conversationID: try status(name, contextPercent: contextPercent)])
        let setup = try await opened(links: .init(agentSessionStatusReaders: [.agy: reader]))
        await setup.model.refreshSessionStatusIfDue()
        return setup
    }

    @Test("裝了 statusline 包裝:context 百分比取自 statusline,模型與 effort 優先用它(去掉模型名稱後面的括號)")
    func statusLineFileGivesContextModelEffort() async throws {
        let setup = try await Self.opened(statusFile: "statusline-default-idle", contextPercent: 37.4)

        #expect(setup.model.header.progress.contextPercent == 37)
        #expect(setup.model.modelName == "Gemini 4 Neon")
        #expect(setup.model.modelSummary == "Gemini 4 Neon · Medium")
    }

    @Test("裝了 statusline 包裝:權限模式取自 cycle_mode,不必讀畫面")
    func cycleModeGivesPermissionMode() async throws {
        for (name, mode) in [("statusline-plan-idle", AgentPermissionMode.plan), ("statusline-auto-idle", .auto), ("statusline-accept-edits-idle", .acceptEdits)] {
            let setup = try await Self.opened(statusFile: name)
            #expect(setup.model.permissionMode == mode, "\(name)")
        }
    }

    @Test("default 模式的 statusline 沒有 cycle_mode:權限模式照畫面狀態列")
    func defaultModeFallsBackToScreen() async throws {
        let setup = try await Self.opened(statusFile: "statusline-default-idle")
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-default"))
        await setup.model.refreshStatusLine()

        #expect(setup.model.permissionMode == .normal)
    }

    @Test("沒有 statusline 檔:照舊用畫面與對話紀錄")
    func withoutStatusFileUsesScreen() async throws {
        let setup = try await Self.opened(links: .init(agentSessionStatusReaders: [.agy: ConversationSessionStatusTests.Reader()]))
        await setup.model.refreshSessionStatusIfDue()
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("agy-idle-plan"))
        await setup.model.refreshStatusLine()

        #expect(setup.model.sessionStatus == nil)
        #expect(setup.model.permissionMode == .plan)
        #expect(setup.model.modelName == "Gemini 4 Neon")
    }
}
