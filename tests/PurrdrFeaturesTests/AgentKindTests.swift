import PurrdrAgentFeatures
import Testing

/// Agent 種類由 herdr 的種類字串解析(#103 review)。
@Suite("Agent 種類")
struct AgentKindTests {
    @Test("herdr 的種類字串對應到種類;沒有專屬樣式的種類保留原文")
    func parsesRawKind() {
        #expect(AgentKind(rawKind: "claude") == .claudeCode)
        #expect(AgentKind(rawKind: "codex") == .codex)
        #expect(AgentKind(rawKind: "gemini") == .gemini)
        #expect(AgentKind(rawKind: "open_code") == .openCode)
        #expect(AgentKind(rawKind: "github_copilot") == .copilot)
        #expect(AgentKind(rawKind: "grok") == .unknown("grok"))
        #expect(AgentKind(rawKind: "") == .unknown(""))
    }

    @Test("顯示名稱：已知種類有固定名稱，其他種類照既有對照或原文")
    func displayNames() {
        #expect(AgentKind.claudeCode.displayName == "Claude Code")
        #expect(AgentKind.openCode.displayName == "opencode")
        #expect(AgentKind.copilot.displayName == "GitHub Copilot")
        #expect(AgentKind.unknown("agy").displayName == "Antigravity")
        #expect(AgentKind.unknown("mystery").displayName == "mystery")
        #expect(AgentKind.unknown("").displayName == nil)
    }
}
