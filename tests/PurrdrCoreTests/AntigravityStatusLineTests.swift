import PurrdrCore
import PurrdrTestSupport
import Testing

/// Antigravity 畫面右下角狀態列「模式 · 模型 · effort」的解析(#446),以真實錄製的畫面(agy 1.5.14)驅動。
@Suite("Antigravity 狀態列")
struct AntigravityStatusLineTests {
    private static let dialect = AgentCatalog.profile(forHerdrName: "agy").screen

    private func read(_ screen: String) -> AgentStatusLine? {
        Self.dialect.readStatusLine(in: PaneScreens.text(screen))
    }

    @Test("四種權限模式的閒置畫面各讀出模式、模型與 effort;default 沒有模式那一段")
    func modes() {
        let expected: [(String, AgentPermissionMode)] = [
            ("agy-idle-auto", .auto), ("agy-idle-plan", .plan), ("agy-idle-accept-edits", .acceptEdits), ("agy-idle-default", .normal),
        ]
        for (screen, mode) in expected {
            let line = read(screen)
            #expect(line == AgentStatusLine(mode: mode, model: "Gemini 4 Neon", effort: "medium"), Comment(rawValue: screen))
        }
    }

    @Test("工作中的畫面(`esc to cancel` 在左邊)也讀得到")
    func working() {
        #expect(read("agy-working") == AgentStatusLine(mode: .normal, model: "Gemini 4 Neon", effort: "medium"))
    }

    @Test("面板、提示、說明畫面開著時,最底下一行仍是狀態列(沿用目前的值)")
    func panelsKeepTheStatusLine() {
        let neon = AgentStatusLine(mode: .normal, model: "Gemini 4 Neon", effort: "medium")
        for screen in ["agy-panel-model", "agy-panel-model-moved", "agy-panel-effort", "agy-help-commands-1", "agy-permission-command", "agy-ask-question"] {
            #expect(read(screen) == neon, Comment(rawValue: screen))
        }
        #expect(read("agy-cli-trust") == AgentStatusLine(mode: .auto, model: "Gemini 4 Neon", effort: "medium"))
    }

    @Test("沒有狀態列方言的種類回 nil")
    func otherAgents() {
        for name in ["claude", "codex", "grok", "unknown-agent"] {
            #expect(AgentCatalog.profile(forHerdrName: name).screen.readStatusLine(in: PaneScreens.text("agy-idle-auto")) == nil, Comment(rawValue: name))
        }
    }

    @Test("模型名含 · 以外的字(版本點、連字號)也完整保留;effort 認 xhigh 與 max")
    func syntheticLines() {
        let screen = "> \n────────────────────\n? for shortcuts            plan · Gemini 3.5 Flash-Lite · xhigh\n"
        #expect(Self.dialect.readStatusLine(in: screen) == AgentStatusLine(mode: .plan, model: "Gemini 3.5 Flash-Lite", effort: "xhigh"))
        let noEffort = "? for shortcuts            auto · Some Model · fast\n"
        #expect(Self.dialect.readStatusLine(in: noEffort) == nil)
    }

    @Test("狀態列只認畫面最底下一行:Agent 回覆文字裡的「a · b · medium」不算")
    func replyTextIsNotStatusLine() {
        let screen = "Result: auto · Gemini 4 Neon · low\n> \n────────────────────\n? for shortcuts            plan · Gemini 4 Neon · high\n\n\n"
        #expect(Self.dialect.readStatusLine(in: screen)?.effort == "high")
        let onlyReply = "Result: auto · Gemini 4 Neon · low\nmore text\n"
        #expect(Self.dialect.readStatusLine(in: onlyReply) == nil)
        let replyLast = "? for shortcuts            plan · Gemini 4 Neon · high\nResult: auto · Gemini 4 Neon · low\n"
        #expect(Self.dialect.readStatusLine(in: replyLast) == nil)
    }
}
