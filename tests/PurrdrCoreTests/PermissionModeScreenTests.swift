import PurrdrCore
import Testing

/// 從 Pane 畫面認權限模式、輪替順序、可用清單(#306、#383)。畫面標示字串取自 Claude Code 2.1.330 本身的模式表
/// (`indicator`:manual mode、plan mode、accept edits、bypass permissions、don't ask、auto mode)。
@Suite("權限模式")
struct PermissionModeScreenTests {
    static func screen(footer: String) -> String {
        "╭──────────────╮\n│ > ▌          │\n╰──────────────╯\n  \(footer)\n"
    }

    @Test(
        "從輸入框下方標示認出模式",
        arguments: [
            ("⏵⏵ accept edits on (shift+tab to cycle)", AgentPermissionMode.acceptEdits),
            ("⏸ plan mode on (shift+tab to cycle)", .plan),
            ("⏵⏵ bypass permissions on (shift+tab to cycle)", .bypassPermissions),
            ("⏵⏵ auto mode on (shift+tab to cycle)", .auto),
            ("⏵⏵ don't ask on (shift+tab to cycle)", .dontAsk),
            ("⏵⏵ don’t ask on (shift+tab to cycle)", .dontAsk),
            ("? for shortcuts", .normal),
            ("⏵⏵ accept edits on (shift+tab to cycle) · esc to interrupt", .acceptEdits),
            ("⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt", .auto),
            ("esc to interrupt", .normal),
        ]
    )
    func parsesFooter(footer: String, expected: AgentPermissionMode) {
        #expect(PermissionModeScreen.parse(Self.screen(footer: footer)) == expected)
    }

    @Test("不是輸入畫面(沒有任何標示)認不出,回 nil")
    func unknownScreen() {
        #expect(PermissionModeScreen.parse("$ ls\nfile.txt\n") == nil)
    }

    @Test("自訂 status line 蓋掉底部標示:閒置的輸入框(兩條分隔線夾著 ❯)判斷為一般模式")
    func customStatusLineIdleIsNormal() {
        let rule = String(repeating: "─", count: 40)
        let screen = "⏺ All set.\n\n\(rule)\n❯\u{00A0}\n\(rule)\n  ledger · Opus 5.5 · ctx 12%\n"
        #expect(PermissionModeScreen.parse(screen) == .normal)
    }

    @Test("自訂 status line 下有明確標示時仍以標示為準")
    func customStatusLineWithIndicator() {
        let rule = String(repeating: "─", count: 40)
        let screen = "\(rule)\n❯\u{00A0}\n\(rule)\n  ledger ctx 12% · ⏸ plan mode on\n"
        #expect(PermissionModeScreen.parse(screen) == .plan)
    }

    @Test("編號選項的對話框(❯ 1. Yes)不是閒置輸入框,認不出")
    func dialogIsNotIdleInput() {
        let rule = String(repeating: "─", count: 40)
        let screen = "\(rule)\n ❯ 1. Yes\n   2. No\n\(rule)\n"
        #expect(PermissionModeScreen.parse(screen) == nil)
    }

    @Test(
        "對話紀錄的 permissionMode 值",
        arguments: [
            ("default", AgentPermissionMode.normal), ("manual", .normal), ("acceptEdits", .acceptEdits), ("plan", .plan),
            ("auto", .auto), ("dontAsk", .dontAsk), ("bypassPermissions", .bypassPermissions), ("bypass", .bypassPermissions),
        ]
    )
    func transcriptValues(value: String, expected: AgentPermissionMode) {
        #expect(AgentPermissionMode(transcriptValue: value) == expected)
    }

    @Test("不認得的紀錄值回 nil")
    func unknownTranscriptValue() {
        #expect(AgentPermissionMode(transcriptValue: "yolo") == nil)
    }

    @Test("預設輪替:一般 → 接受編輯 → Plan → 一般;略過權限與不詢問回到一般")
    func defaultCycleOrder() {
        #expect(AgentPermissionMode.normal.next() == .acceptEdits)
        #expect(AgentPermissionMode.acceptEdits.next() == .plan)
        #expect(AgentPermissionMode.plan.next() == .normal)
        #expect(AgentPermissionMode.bypassPermissions.next() == .normal)
        #expect(AgentPermissionMode.dontAsk.next() == .normal)
    }

    @Test("輪替依 Claude Code:Plan 之後先略過權限、再自動、最後回一般")
    func extendedCycleOrder() {
        let both: Set<AgentPermissionMode> = [.normal, .acceptEdits, .plan, .bypassPermissions, .auto]
        #expect(AgentPermissionMode.plan.next(available: both) == .bypassPermissions)
        #expect(AgentPermissionMode.bypassPermissions.next(available: both) == .auto)
        #expect(AgentPermissionMode.auto.next(available: both) == .normal)
        let autoOnly: Set<AgentPermissionMode> = [.normal, .acceptEdits, .plan, .auto]
        #expect(AgentPermissionMode.plan.next(available: autoOnly) == .auto)
        #expect(AgentPermissionMode.auto.next(available: autoOnly) == .normal)
    }

    @Test("dontAsk 只顯示、不能切換")
    func dontAskIsDisplayOnly() {
        #expect(!AgentPermissionMode.dontAsk.isSwitchable)
        #expect(AgentPermissionMode.allCases.filter(\.isSwitchable).count == 5)
    }
}

@Suite("權限模式可用清單")
struct PermissionModeAvailabilityTests {
    @Test("預設:一般、接受編輯、Plan")
    func defaults() {
        let availability = PermissionModeAvailability()
        #expect(availability.options(current: nil) == [.normal, .acceptEdits, .plan])
    }

    @Test("看過略過權限或自動就加進清單,依輪替順序")
    func observedModesAreAdded() {
        var availability = PermissionModeAvailability()
        availability.observe(.auto)
        #expect(availability.options(current: .auto) == [.normal, .acceptEdits, .plan, .auto])
        availability.observe(.bypassPermissions)
        #expect(availability.options(current: .auto) == [.normal, .acceptEdits, .plan, .bypassPermissions, .auto])
    }

    @Test("看過 dontAsk 不會變成可切換的選項,但目前是它時附在最後顯示")
    func dontAskOnlyShownWhenCurrent() {
        var availability = PermissionModeAvailability()
        availability.observe(.dontAsk)
        #expect(availability.options(current: .plan) == [.normal, .acceptEdits, .plan])
        #expect(availability.options(current: .dontAsk) == [.normal, .acceptEdits, .plan, .dontAsk])
    }

    @Test(
        "從 claude 啟動參數判斷",
        arguments: [
            ("claude --dangerously-skip-permissions", [AgentPermissionMode.bypassPermissions]),
            ("claude --allow-dangerously-skip-permissions", [.bypassPermissions]),
            ("claude --permission-mode auto", [.auto]),
            ("claude --permission-mode=bypassPermissions", [.bypassPermissions]),
            ("claude --permission-mode plan", []),
            ("claude --enable-auto-mode", [.auto]),
            ("claude", []),
        ]
    )
    func launchCommand(command: String, added: [AgentPermissionMode]) {
        var availability = PermissionModeAvailability()
        availability.apply(launchCommand: command, settingsJSON: [])
        #expect(availability.modes.subtracting(AgentPermissionMode.defaultAvailable) == Set(added))
    }

    @Test("從設定的 permissions.defaultMode 判斷;壞掉的設定忽略")
    func settingsDefaultMode() {
        var availability = PermissionModeAvailability()
        availability.apply(launchCommand: nil, settingsJSON: ["not json", #"{"permissions":{"defaultMode":"auto"}}"#])
        #expect(availability.modes.contains(.auto))
        #expect(!availability.modes.contains(.bypassPermissions))
    }
}

@Suite("對話紀錄的權限模式")
struct TranscriptPermissionModeTests {
    @Test("permission-mode 紀錄:以最後一筆為準")
    func lastEntryWins() {
        let lines = [
            #"{"type":"permission-mode","permissionMode":"plan","sessionId":"s"}"#,
            #"{"type":"permission-mode","permissionMode":"acceptEdits","sessionId":"s"}"#,
        ]
        #expect(TranscriptMetadata.latest(in: lines).permissionMode == "acceptEdits")
    }

    @Test("使用者訊息帶的 permissionMode 也算(紀錄尚未寫獨立的 permission-mode 行)")
    func userMessageField() {
        let lines = [#"{"type":"user","message":{"role":"user","content":"hi"},"permissionMode":"auto","uuid":"u1"}"#]
        #expect(TranscriptMetadata.latest(in: lines).permissionMode == "auto")
    }

    @Test("不認得的值不覆蓋較早的")
    func unknownValueIgnored() {
        let lines = [
            #"{"type":"permission-mode","permissionMode":"plan"}"#,
            #"{"type":"permission-mode","permissionMode":"future-mode"}"#,
        ]
        #expect(TranscriptMetadata.latest(in: lines).permissionMode == "plan")
    }

    @Test("Codex 的核准政策取 turn_context")
    func codexApprovalPolicy() {
        let line = #"{"type":"turn_context","payload":{"model":"gpt-5","approval_policy":"on-request"}}"#
        var metadata = TranscriptMetadata()
        CodexTranscriptParser.updateMetadata(&metadata, with: line)
        #expect(metadata.approvalPolicy == "on-request")
    }
}
