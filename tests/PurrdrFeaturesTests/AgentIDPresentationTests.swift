import PurrdrAgentFeatures
import PurrdrCore
import Testing

/// Agent 種類由 herdr 的種類字串解析(#103 review)。
@Suite("Agent 種類")
struct AgentIDPresentationTests {
    @Test("herdr 的種類字串對應到種類;沒有專屬樣式的種類保留原文")
    func parsesRawKind() {
        #expect(AgentID(herdrName: "claude") == .claude)
        #expect(AgentID(herdrName: "codex") == .codex)
        #expect(AgentID(herdrName: "gemini") == .gemini)
        #expect(AgentID(herdrName: "open_code") == .opencode)
        #expect(AgentID(herdrName: "github_copilot") == .copilot)
        #expect(AgentID(herdrName: "grok") == .grok)
        #expect(AgentID(herdrName: "") == .other(""))
    }

    @Test("herdr 的正式名稱與別名都對應到同一種類(#435)")
    func parsesHerdrNamesAndAliases() {
        for name in ["opencode", "opencode2", "open-code"] { #expect(AgentID(herdrName: name) == .opencode) }
        for name in ["copilot", "github-copilot", "ghcs"] { #expect(AgentID(herdrName: name) == .copilot) }
        for name in ["agy", "antigravity", "antigravity-cli"] { #expect(AgentID(herdrName: name).displayName == "Antigravity") }
        #expect(AgentKindSymbol.name(for: "opencode") == "curlybraces")
        #expect(AgentKindSymbol.name(for: "ghcs") == "airplane")
        #expect(AgentKindSymbol.name(for: "antigravity-cli") == AgentKindSymbol.name(for: "agy"))
    }

    @Test("顯示名稱：已知種類有固定名稱，其他種類照既有對照或原文")
    func displayNames() {
        #expect(AgentID.claude.displayName == "Claude Code")
        #expect(AgentID.opencode.displayName == "opencode")
        #expect(AgentID.copilot.displayName == "GitHub Copilot")
        #expect(AgentID.agy.displayName == "Antigravity")
        #expect(AgentID.other("mystery").displayName == "mystery")
        #expect(AgentID.other("").displayName == nil)
    }
}
