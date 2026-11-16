import PurrdrCore
import PurrdrTestSupport
import Testing

/// slash 指令開出的面板(`/model`、`/effort`…;#45、行為規格 F9.4、§5.6)。畫面是依規格手寫的(`Fixtures/screens/*-panel-*.txt`)。
@Suite("Slash 面板解析")
struct SlashPanelParserTests {
    static func parse(_ name: String, kind: String = "claude") -> SlashPanel? {
        SlashPanelParser.parse(screen: PaneScreens.text(name), agentKind: kind)
    }

    @Test("Claude 模型面板：標題、說明、選項(目前值打勾、游標列)、←/→ 調整、面板自己的動作")
    func claudeModelPanel() throws {
        let panel = try #require(Self.parse("claude-panel-model"))
        #expect(panel.title == "Select model")
        #expect(panel.notes == ["Switch between models. Applies to this session and future sessions."])
        #expect(panel.options.map(\.label) == ["Default (recommended)", "Sonnet", "Haiku"])
        #expect(panel.options.map(\.detail) == ["Opus · Most capable for complex work", "Sonnet · Best for everyday tasks", "Haiku · Fastest for quick answers"])
        #expect(panel.options.map(\.isCurrent) == [false, true, false])
        #expect(panel.options.map(\.isCursor) == [false, true, false])
        #expect(panel.adjustment == "◐ Medium effort")
        #expect(panel.slider == nil)
        #expect(panel.actions == [
            SlashPanelAction(key: "enter", label: "set as default"),
            SlashPanelAction(key: "s", label: "use this session only"),
            SlashPanelAction(key: "esc", label: "cancel"),
        ])
    }

    @Test("Claude effort 面板：▲ 滑桿下一行是層級名，目前層級是 ▲ 所對的那個")
    func claudeEffortSlider() throws {
        let panel = try #require(Self.parse("claude-panel-effort"))
        #expect(panel.title == "Effort")
        #expect(panel.options.isEmpty)
        #expect(panel.slider == SlashPanelSlider(levels: ["low", "medium", "high", "xhigh", "max"], current: 1))
        #expect(panel.adjustment != nil)
        #expect(panel.actions.map(\.key) == ["enter", "esc"])
    }

    @Test("沒有提示行、有選單且沒有輸入框的確認畫面(Switch model?)也是面板;沒有動作時給確認與取消")
    func claudeConfirmWithoutHint() throws {
        let panel = try #require(Self.parse("claude-panel-confirm"))
        #expect(panel.title == "Switch model?")
        #expect(panel.options.map(\.label) == ["Yes, switch", "No, go back"])
        #expect(panel.actions.map(\.key) == ["enter", "esc"])
    }

    @Test("Codex 面板：以頁尾辨識，(current) 是目前值，動作是確認與返回")
    func codexPanel() throws {
        let panel = try #require(Self.parse("codex-panel-model", kind: "codex"))
        #expect(panel.title == "Select Model and Effort")
        #expect(panel.notes == ["Switch the model for this and future Codex sessions"])
        #expect(panel.options.map(\.label) == ["gpt-5.1-codex", "gpt-5.1", "gpt-5.1-codex-mini"])
        #expect(panel.options.map(\.isCurrent) == [true, false, false])
        #expect(panel.options.map(\.isCursor) == [true, false, false])
        #expect(panel.actions.map(\.key) == ["enter", "esc"])
    }

    @Test("閒置畫面、需要你的權限提示不是面板")
    func otherScreensAreNotPanels() {
        #expect(Self.parse("claude-idle") == nil)
        #expect(Self.parse("claude-bash") == nil)
        #expect(Self.parse("codex-command", kind: "codex") == nil)
        #expect(Self.parse("claude-panel-model", kind: "pi") == nil)
    }

    // MARK: - 按鍵(R-C04:永不送數字)

    @Test("點選項：從游標列送 down／up × 差距，只移動游標、永不送數字")
    func selectingSendsArrowsNeverDigits() throws {
        let panel = try #require(Self.parse("claude-panel-model"))
        #expect(panel.keys(for: .select(panel.options[0])) == ["up"])
        #expect(panel.keys(for: .select(panel.options[2])) == ["down"])
        #expect(panel.keys(for: .select(panel.options[1])) == [])
        let codex = try #require(Self.parse("codex-panel-model", kind: "codex"))
        #expect(codex.keys(for: .select(codex.options[2])) == ["down", "down"])
    }

    @Test("沒有游標列時選項停用(不知道要移多少)")
    func noCursorDisablesOptions() throws {
        var panel = try #require(Self.parse("claude-panel-model"))
        panel.options = panel.options.map { option in
            var option = option
            option.isCursor = false
            return option
        }
        #expect(panel.keys(for: .select(panel.options[0])) == nil)
    }

    @Test("滑桿層級送 left／right × 差距;←/→ 調整送一個方向鍵;動作送它自己的鍵")
    func sliderAdjustAndActions() throws {
        let effort = try #require(Self.parse("claude-panel-effort"))
        #expect(effort.keys(for: .level(3)) == ["right", "right"])
        #expect(effort.keys(for: .level(0)) == ["left"])
        #expect(effort.keys(for: .adjust(.left)) == ["left"])
        #expect(effort.keys(for: .adjust(.right)) == ["right"])
        let model = try #require(Self.parse("claude-panel-model"))
        #expect(model.keys(for: .action(model.actions[1])) == ["s"])
        let confirm = try #require(Self.parse("claude-panel-confirm"))
        #expect(confirm.keys(for: .adjust(.right)) == nil)
    }

    @Test("提示行上的數字鍵動作不收(數字在模型選擇器會直接存成預設)")
    func digitActionsAreDropped() throws {
        let screen = PaneScreens.text("claude-panel-model")
            .replacingOccurrences(of: "s to use this session only", with: "1 to pick the first")
        let panel = try #require(SlashPanelParser.parse(screen: screen, agentKind: "claude"))
        #expect(panel.actions.map(\.key) == ["enter", "esc"])
    }
}
