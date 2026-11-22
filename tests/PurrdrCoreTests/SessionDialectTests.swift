import PurrdrCore
import Testing

/// Agent 設定檔的 session 組(#442、ADR-0013):新聊天、恢復與 session 標題規則。
@Suite("Agent 設定檔的 session 組")
struct SessionDialectTests {
    private static func session(_ herdrName: String) -> SessionDialect {
        AgentCatalog.profile(forHerdrName: herdrName).session
    }

    @Test("新聊天可啟動的種類與順序:Claude、Codex、Grok、Antigravity、Pi、OMP;herdr 的 kind 是正式名稱")
    func startableAgents() {
        #expect(AgentCatalog.startableAgents == [.claude, .codex, .grok, .agy, .pi, .omp])
        #expect(AgentCatalog.startableAgents.map(\.canonicalName) == ["claude", "codex", "grok", "agy", "pi", "omp"])
        #expect(Set(AgentCatalog.startableAgents) == Set(AgentID.allCases.filter { AgentCatalog.profile(for: $0).session.startsNewChat }))
        for name in ["gemini", "opencode", "copilot", "cursor", "unknown-agent"] {
            #expect(!Self.session(name).startsNewChat, "\(name)")
        }
    }

    @Test("啟動參數:權限模式旗標只有 Claude Code")
    func permissionFlag() {
        #expect(Self.session("claude").permissionModeFlag == "--permission-mode")
        for name in ["codex", "grok", "agy", "pi", "omp", "gemini"] {
            #expect(Self.session(name).permissionModeFlag == nil, "\(name)")
        }
    }

    @Test("恢復:只有 Claude Code 與 Codex,主機服務的種類是正式名稱")
    func resume() {
        #expect(Self.session("claude").resumeKind == "claude")
        #expect(Self.session("codex").resumeKind == "codex")
        for name in ["grok", "agy", "pi", "omp", "gemini", "unknown-agent"] {
            #expect(Self.session(name).resumeKind == nil, "\(name)")
        }
        #expect(AgentID.claude.supportsResume && AgentID.codex.supportsResume && !AgentID.agy.supportsResume)
    }

    @Test("session 標題:Claude 與其他種類取 herdr 的 title,沒有才取終端機標題")
    func defaultTitle() {
        let claude = Self.session("claude")
        #expect(claude.title(sessionTitle: "整理標籤", terminalTitle: "terminal") == "整理標籤")
        #expect(claude.title(sessionTitle: nil, terminalTitle: "  修 bug  ") == "修 bug")
        #expect(Self.session("unknown-agent").title(sessionTitle: nil, terminalTitle: "x") == "x")
    }

    @Test("session 標題:預設終端機標題、resume 指令與像 session id 的字串都不算")
    func rejectedTitles() {
        let claude = Self.session("claude")
        for rejected in ["Claude Code", "claude", "claude --resume abc", "x --continue", "codex resume 019a", "agy", "omp", "grok",
                         "deadbeef-1234 something", "   "] {
            #expect(claude.title(sessionTitle: nil, terminalTitle: rejected) == nil, "\(rejected)")
        }
    }

    @Test("session 標題:Codex 取終端機標題去掉結尾「 | 資料夾」,不用被截斷的 title")
    func codexTitle() {
        let codex = Self.session("codex")
        #expect(codex.title(sessionTitle: "被截斷的第一個 prompt…", terminalTitle: "修正匯出 | ledger") == "修正匯出")
        #expect(codex.title(sessionTitle: "被截斷", terminalTitle: "沒有分隔") == nil)
        #expect(codex.title(sessionTitle: "被截斷", terminalTitle: nil) == nil)
    }

    @Test("session 標題:Grok 取終端機標題去掉前導 spinner、Action Required 與「 - grok」")
    func grokTitle() {
        let grok = Self.session("grok")
        #expect(grok.title(sessionTitle: "忽略", terminalTitle: "⠋ 整理筆記 - grok") == "整理筆記")
        #expect(grok.title(sessionTitle: nil, terminalTitle: "Action Required 整理筆記 - Grok") == "整理筆記")
        #expect(grok.title(sessionTitle: nil, terminalTitle: "grok") == nil)
    }

    @Test("每份設定檔的 session 組都標明驗證狀態")
    func verification() {
        #expect(Self.session("claude").verification == .verified(agentVersion: "Claude Code 2.1.300–2.1.325"))
        #expect(Self.session("grok").verification == .unverified(documentedFor: "Grok 1.0.52"))
    }
}
