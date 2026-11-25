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
        case .auto: "⏵⏵ auto mode on (shift+tab to cycle)"
        case .dontAsk: "⏵⏵ don't ask on (shift+tab to cycle)"
        }
        return PaneScreens.read(text: "│ > ▌ │\n  \(footer)\n")
    }

    /// 對話紀錄裡一筆權限模式紀錄(Claude Code 切換時寫的 `permission-mode` 行)。
    static func modeLine(_ value: String) -> Data {
        Data((#"{"type":"permission-mode","permissionMode":"\#(value)","sessionId":"\#(ConversationModelTests.sessionID)"}"# + "\n").utf8)
    }

    /// 開好聊天。預設的對話紀錄沒有任何權限模式紀錄(把 fixture 裡使用者訊息的欄位拿掉),讓畫面判斷單獨運作;
    /// 帶 `transcriptMode` 時在尾端加一筆權限模式紀錄。
    static func opened(transcriptMode: String? = nil, links: ConversationModel.HostLinks = .init()) async throws -> ConversationAnswerTests.Setup {
        let setup = try ConversationAnswerTests.setup(sleeper: RecordingSleeper { $0 == .milliseconds(300) }, links: links)
        let stripped = String(decoding: ConversationModelTests.fixture, as: UTF8.self)
            .replacingOccurrences(of: #""permissionMode":"bypassPermissions""#, with: #""note":"x""#)
        try setup.shell.write(Data(stripped.utf8), to: ConversationModelTests.transcriptPath)
        if let transcriptMode { try setup.shell.append(modeLine(transcriptMode), to: ConversationModelTests.transcriptPath) }
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
        #expect(setup.model.permissionModeFailure == .modeUnavailable(.bypassPermissions))
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

    // MARK: - 以對話紀錄為準(#383)

    @Test("對話紀錄的最後一筆權限模式為準:畫面讀到不同的值也不蓋掉")
    func transcriptWinsOverScreen() async throws {
        let setup = try await Self.opened(transcriptMode: "plan")
        #expect(setup.model.permissionMode == .plan)
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))

        await setup.model.refreshPermissionMode()

        #expect(setup.model.permissionMode == .plan)
    }

    @Test("電腦端改了模式:對話紀錄多一筆就同步,不需要讀畫面")
    func desktopChangeSyncsFromTranscript() async throws {
        let setup = try await Self.opened(transcriptMode: "plan")
        let readsBefore = await ConversationAnswerTests.paneReads(setup)
        try setup.shell.append(Self.modeLine("acceptEdits"), to: ConversationModelTests.transcriptPath)
        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "idle"))

        await setup.model.poll()

        #expect(setup.model.permissionMode == .acceptEdits)
        #expect(await ConversationAnswerTests.paneReads(setup) == readsBefore)
    }

    @Test(
        "認得 6 種模式(對話紀錄的值)",
        arguments: [
            ("default", AgentPermissionMode.normal), ("acceptEdits", .acceptEdits), ("plan", .plan),
            ("auto", .auto), ("dontAsk", .dontAsk), ("bypassPermissions", .bypassPermissions),
        ]
    )
    func sixModes(value: String, expected: AgentPermissionMode) async throws {
        let setup = try await Self.opened(transcriptMode: value)
        #expect(setup.model.permissionMode == expected)
    }

    @Test("剛切換、紀錄尚未寫入:畫面補空檔;紀錄一更新就以紀錄為準")
    func screenFillsGapUntilTranscriptCatchesUp() async throws {
        let setup = try await Self.opened(transcriptMode: "default")
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.acceptEdits))

        await setup.model.setPermissionMode(.acceptEdits)
        #expect(setup.model.permissionMode == .acceptEdits, "紀錄還是 default,以畫面補上")

        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "idle"))
        await setup.model.poll()
        #expect(setup.model.permissionMode == .acceptEdits, "紀錄沒變,仍用畫面")

        try setup.shell.append(Self.modeLine("plan"), to: ConversationModelTests.transcriptPath)
        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "idle"))
        await setup.model.poll()
        #expect(setup.model.permissionMode == .plan, "電腦端又改了,以紀錄為準")
    }

    // MARK: - 可用清單與切不到(#383)

    @Test("預設清單:一般、接受編輯、Plan;紀錄看過 auto 才加入 auto")
    func optionsAreDynamic() async throws {
        let setup = try await Self.opened(transcriptMode: "plan")
        #expect(setup.model.permissionModeOptions == [.normal, .acceptEdits, .plan])

        try setup.shell.append(Self.modeLine("auto"), to: ConversationModelTests.transcriptPath)
        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "idle"))
        await setup.model.poll()
        try setup.shell.append(Self.modeLine("plan"), to: ConversationModelTests.transcriptPath)
        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "idle"))
        await setup.model.poll()

        #expect(setup.model.permissionMode == .plan)
        #expect(setup.model.permissionModeOptions == [.normal, .acceptEdits, .plan, .auto], "看過就留在清單")
    }

    @Test("目前是 dontAsk:清單多一列顯示它,但選不到也切不過去")
    func dontAskIsDisplayedNotSwitchable() async throws {
        let setup = try await Self.opened(transcriptMode: "dontAsk")
        #expect(setup.model.permissionModeOptions == [.normal, .acceptEdits, .plan, .dontAsk])

        await setup.model.setPermissionMode(.dontAsk)

        #expect(await Self.shiftTabCount(setup) == 0)
        #expect(setup.model.permissionModeFailure == nil)
    }

    @Test("沒開 auto:輪替一圈沒出現就停,說明切不到、不連按")
    func autoUnavailableStopsAfterOneCycle() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.normal))
        for shown in [AgentPermissionMode.acceptEdits, .plan, .normal] {
            await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
            await setup.host.bridge.expect(Self.bridge, reply: Self.screen(shown))
        }

        await setup.model.setPermissionMode(.auto)

        #expect(await Self.shiftTabCount(setup) == 3)
        #expect(setup.model.permissionModeFailure == .modeUnavailable(.auto))
        #expect(setup.model.permissionModeFailure?.target == nil, "再試沒有意義")
    }

    @Test("畫面上出現 auto 就算可用:輪替到 auto 切換成功並加入清單")
    func autoSeenOnScreenBecomesAvailable() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.plan))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.screen(.auto))

        await setup.model.setPermissionMode(.auto)

        #expect(setup.model.permissionMode == .auto)
        #expect(setup.model.permissionModeFailure == nil)
        #expect(setup.model.permissionModeOptions.contains(.auto))
    }

    @Test("Agent 在等使用者:不送 Shift+Tab(避免變成核准)")
    func blockedSendsNoKeys() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-bash"))
        await setup.model.poll()
        #expect(setup.model.permissionModeLock == .waitingForYou)

        await setup.model.setPermissionMode(.plan)

        #expect(await Self.shiftTabCount(setup) == 0)
    }

    @Test("自訂 status line 下閒置:輸入框判斷為一般模式")
    func customStatusLineIdle() async throws {
        let setup = try await Self.opened()
        let rule = String(repeating: "─", count: 40)
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: "\(rule)\n❯\u{00A0}\n\(rule)\n  ledger · ctx 12%\n"))

        await setup.model.refreshPermissionMode()

        #expect(setup.model.permissionMode == .normal)
    }

    // MARK: - Codex 只顯示核准政策(#383)

    @Test("Codex:顯示核准政策,沒有權限模式與切換")
    func codexShowsApprovalPolicyOnly() async throws {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: CodexConversationTests.sessionID)
        try setup.shell.write(Fixtures.otherAgentTranscript("codex/rollout.jsonl"), to: CodexConversationTests.rollout)
        try setup.shell.append(
            Data((#"{"type":"turn_context","payload":{"model":"gpt-5.5","approval_policy":"on-request"}}"# + "\n").utf8),
            to: CodexConversationTests.rollout)
        await setup.host.bridge.expect(Self.bridge, reply: CodexConversationTests.snapshot())

        await setup.model.poll()

        #expect(setup.model.approvalPolicy == "on-request")
        #expect(!setup.model.supportsPermissionMode)
        #expect(!setup.model.canSwitchPermissionMode)
    }
}
