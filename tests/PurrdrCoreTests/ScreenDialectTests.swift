import PurrdrCore
import PurrdrTestSupport
import Testing

/// Agent 設定檔的畫面組(#441、ADR-0013):面板、檔案選擇器、權限模式、選模型的驗證開關,與 ACP 詞彙的輸出。
/// 解析一律以錄製的畫面(`Fixtures/screens/`)驅動。
@Suite("Agent 設定檔的畫面組")
struct ScreenDialectTests {
    private static func dialect(_ herdrName: String) -> ScreenDialect {
        AgentCatalog.profile(forHerdrName: herdrName).screen
    }

    private static func unverified(
        panel: ScreenDialect.PanelStyle? = nil, hasPermissionModes: Bool = false, choosesModel: Bool = false
    ) -> ScreenDialect {
        ScreenDialect(
            name: "test", verification: .unverified(documentedFor: "test"), panel: panel,
            hasPermissionModes: hasPermissionModes, choosesModel: choosesModel
        )
    }

    // MARK: - 設定檔目錄

    @Test("Claude 與 Codex 有面板格式;其他種類用通用畫面組(什麼都不讀、不操作)")
    func catalogAssignment() {
        #expect(Self.dialect("claude").panel == .claude)
        #expect(Self.dialect("codex").panel == .codex)
        for name in ["grok", "pi", "gemini", "unknown-agent"] {
            #expect(Self.dialect(name) == .generic, "\(name)")
        }
        #expect(ScreenDialect.generic.configurableCategories.isEmpty)
        #expect(!ScreenDialect.generic.readsPanels)
    }

    @Test("能力:權限模式、選模型、建議只有 Claude;核准政策與檔案選擇器只有 Codex")
    func capabilities() {
        let claude = Self.dialect("claude"), codex = Self.dialect("codex")
        #expect(claude.switchesPermissionMode && claude.canChooseModel && claude.readsPromptSuggestions)
        #expect(!codex.switchesPermissionMode && !codex.canChooseModel && !codex.readsPromptSuggestions)
        #expect(codex.showsApprovalPolicy && codex.detectsFilePicker && codex.showsModelName && codex.transcriptStartsAfterFirstMessage)
        #expect(!claude.showsApprovalPolicy && !claude.detectsFilePicker && !claude.transcriptStartsAfterFirstMessage)
        #expect(claude.configurableCategories == [.mode, .model, .effort])
        #expect(codex.configurableCategories.isEmpty)
    }

    @Test("Antigravity:只讀狀態列並顯示模型;面板、權限模式切換、選模型要送按鍵,還沒開放(#446)")
    func antigravityReadsOnly() {
        let agy = Self.dialect("agy")
        #expect(agy.statusLine == .antigravity && agy.showsModelName && agy.isVerified)
        #expect(!agy.readsPanels && !agy.switchesPermissionMode && !agy.canChooseModel)
        #expect(agy.configurableCategories.isEmpty)
        #expect(Self.dialect("claude").statusLine == nil && Self.dialect("codex").statusLine == nil)
    }

    @Test("herdr 的別名(claude-code)也取到同一份畫面組")
    func aliasResolves() {
        #expect(Self.dialect("claude-code") == Self.dialect("claude"))
    }

    // MARK: - 驗證開關

    @Test("沒驗證過的方言:面板、權限模式切換、選模型都不開放,session 設定類別是空的")
    func unverifiedDialectOpensNothing() {
        let dialect = Self.unverified(panel: .claude, hasPermissionModes: true, choosesModel: true)
        #expect(!dialect.isVerified)
        #expect(!dialect.readsPanels)
        #expect(!dialect.switchesPermissionMode)
        #expect(!dialect.canChooseModel)
        #expect(dialect.configurableCategories.isEmpty)
    }

    @Test("驗證過但沒有那項能力也不開放")
    func verifiedWithoutCapability() {
        let dialect = ScreenDialect(name: "test", verification: .verified(agentVersion: "1"))
        #expect(!dialect.readsPanels && !dialect.switchesPermissionMode && !dialect.canChooseModel)
    }

    // MARK: - 面板(錄製畫面)

    @Test("Claude 方言解析 /model 面板為 model 設定;effort 滑桿為 effort 設定")
    func claudePanelsAsSessionConfig() throws {
        let dialect = Self.dialect("claude")
        let model = try #require(SlashPanelParser.parse(screen: PaneScreens.text("claude-panel-model"), dialect: dialect))
        let modelConfig = try #require(model.sessionConfig)
        #expect(modelConfig.category == .model)
        #expect(modelConfig.values.first == "Default (recommended)")
        #expect(modelConfig.currentIndex == 1)

        let effort = try #require(SlashPanelParser.parse(screen: PaneScreens.text("claude-panel-effort"), dialect: dialect))
        let effortConfig = try #require(effort.sessionConfig)
        #expect(effortConfig.category == .effort)
        #expect(effortConfig.currentIndex != nil)
    }

    @Test("通用方言與 Antigravity 不解析 Claude 的面板畫面", arguments: ["unknown-agent", "agy"])
    func otherDialectsDoNotParsePanels(name: String) {
        #expect(SlashPanelParser.parse(screen: PaneScreens.text("claude-panel-model"), dialect: Self.dialect(name)) == nil)
    }

    @Test("以 agentKind 呼叫與以方言呼叫結果相同")
    func agentKindWrapperMatches() {
        let screen = PaneScreens.text("claude-panel-model")
        #expect(SlashPanelParser.parse(screen: screen, agentKind: "claude") == SlashPanelParser.parse(screen: screen, dialect: Self.dialect("claude")))
    }

    // MARK: - 需要你的補充解析

    @Test("Codex 的 @ 檔案選擇器只有 Codex 方言認得")
    func filePickerOnlyForCodex() throws {
        let screen = PaneScreens.text("codex-file-picker")
        let prompt = try #require(BlockedPromptParser.parse(screen: screen, dialect: Self.dialect("codex")))
        #expect(prompt.kind == .filePicker)
        let other = BlockedPromptParser.parse(screen: screen, dialect: Self.dialect("claude"))
        #expect(other?.kind != .filePicker)
    }

    // MARK: - ACP 權限選項

    @Test("Claude 的 Bash 權限提示:是／不再詢問／否 對應 allowOnce、allowAlways、rejectOnce")
    func claudePermissionOptions() throws {
        let prompt = try #require(BlockedPromptParser.parse(screen: PaneScreens.text("claude-bash"), dialect: Self.dialect("claude")))
        let kinds = prompt.permissionOptions.map(\.kind)
        #expect(kinds.first == .allowOnce)
        #expect(kinds.last == .rejectOnce)
        #expect(kinds.contains(.allowAlways))
    }

    @Test("Antigravity 的權限提示:兩種 always allow 與取消")
    func antigravityPermissionOptions() throws {
        let prompt = try #require(BlockedPromptParser.parse(screen: PaneScreens.text("agy-permission-command"), dialect: Self.dialect("agy")))
        #expect(prompt.permissionOptions.map(\.kind) == [.allowOnce, .allowAlways, .allowAlways, .rejectOnce])
    }

    @Test("Codex 的命令核准:同意與拒絕都有")
    func codexPermissionOptions() throws {
        let prompt = try #require(BlockedPromptParser.parse(screen: PaneScreens.text("codex-command"), dialect: Self.dialect("codex")))
        let kinds = prompt.permissionOptions.map(\.kind)
        #expect(kinds.contains(.allowOnce))
        #expect(kinds.contains(where: { !$0.isAllow }))
    }

    @Test("問答(沒有同意與拒絕)不算權限提示")
    func questionIsNotPermission() throws {
        let prompt = try #require(BlockedPromptParser.parse(screen: PaneScreens.text("claude-ask-question"), dialect: Self.dialect("claude")))
        #expect(prompt.permissionOptions.isEmpty)
    }

    @Test("選項文字分類", arguments: [
        ("Yes", PermissionOptionKind.allowOnce),
        ("Yes, and don't ask again for this command", .allowAlways),
        ("Yes, allow all edits during this session", .allowAlways),
        ("No", .rejectOnce),
        ("No, cancel", .rejectOnce),
        ("No, and don't ask again", .rejectAlways),
        ("Deny", .rejectOnce),
    ])
    func classify(label: String, expected: PermissionOptionKind) {
        #expect(PermissionOptionKind.classify(label: label) == expected)
    }

    @Test("不像權限的文字與 Nothing 這類 No 開頭的字不分類")
    func classifyRejectsOthers() {
        #expect(PermissionOptionKind.classify(label: "Nothing special") == nil)
        #expect(PermissionOptionKind.classify(label: "Type something.") == nil)
    }
}
