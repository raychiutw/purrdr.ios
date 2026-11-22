import PurrdrCore
import Testing

/// Agent 種類與 Agent 設定檔的顯示組(#438、ADR-0013)。
@Suite("Agent 設定檔目錄")
struct AgentCatalogTests {
    /// herdr 的 canonical label(`src/detect/mod.rs` 的 `agent_label`,24 種)。
    private static let herdrLabels = [
        "pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline", "omp", "mastracode", "opencode", "copilot",
        "kimi", "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli", "qwen", "letta", "maki", "muse",
    ]

    @Test("herdr 的 24 個正式名稱都認得，且轉回自己")
    func canonicalLabelsRoundTrip() {
        #expect(AgentID.allCases.count == 24)
        for label in Self.herdrLabels {
            let id = AgentID(herdrName: label)
            #expect(id != .other(label), "\(label) 不該退回其他種類")
            #expect(id.canonicalName == label)
        }
    }

    @Test("herdr 的別名統一成同一個種類(照 lookup_agent)", arguments: [
        ("claude-code", "claude"), ("antigravity", "agy"), ("antigravity-cli", "agy"),
        ("opencode2", "opencode"), ("open-code", "opencode"), ("github-copilot", "copilot"), ("ghcs", "copilot"),
        ("grok-build", "grok"), ("cursor-agent", "cursor"), ("kiro-cli", "kiro"), ("qwen-code", "qwen"),
        ("open_code", "opencode"), ("github_copilot", "copilot"),
    ])
    func aliases(alias: String, canonical: String) {
        #expect(AgentID(herdrName: alias) == AgentID(herdrName: canonical))
        #expect(AgentID(herdrName: alias).canonicalName == canonical)
    }

    @Test("認不得的字串是其他種類，保留原文")
    func unknownStaysOther() {
        #expect(AgentID(herdrName: "mystery") == .other("mystery"))
        #expect(AgentID(herdrName: "mystery").canonicalName == "mystery")
        #expect(AgentID(herdrName: "") == .other(""))
        #expect(AgentCatalog.profile(for: .other("mystery")).presentation.displayName == "mystery")
        #expect(AgentCatalog.profile(for: .other("")).presentation.displayName == nil)
        #expect(AgentCatalog.profile(for: .other("mystery")).presentation.symbolName == "terminal")
    }

    @Test("每種種類都有名稱與圖示;OpenCode、Copilot、Antigravity 顯示正確")
    func presentation() {
        for id in AgentID.allCases {
            let presentation = AgentCatalog.profile(for: id).presentation
            #expect(presentation.displayName?.isEmpty == false)
            #expect(presentation.symbolName.isEmpty == false)
        }
        func name(_ raw: String) -> String? { AgentCatalog.profile(for: AgentID(herdrName: raw)).presentation.displayName }
        func symbol(_ raw: String) -> String { AgentCatalog.profile(for: AgentID(herdrName: raw)).presentation.symbolName }
        #expect(name("opencode") == "opencode")
        #expect(name("open-code") == "opencode")
        #expect(name("ghcs") == "GitHub Copilot")
        #expect(name("antigravity") == "Antigravity")
        #expect(name("claude") == "Claude Code")
        #expect(symbol("opencode") == "curlybraces")
        #expect(symbol("antigravity-cli") == symbol("agy"))
        #expect(symbol("agy") == "arrow.up.forward.circle")
    }

    @Test("頭像:五個專屬配色與字母，其餘種類用中性色")
    func avatar() {
        func avatar(_ raw: String) -> AgentAvatar { AgentCatalog.profile(for: AgentID(herdrName: raw)).presentation.avatar }
        #expect(avatar("claude").letter == "C")
        #expect(avatar("claude").normal == AgentAvatar.Color(red: 0x8A, green: 0x5A, blue: 0x48))
        #expect(avatar("copilot").letter == "P")
        #expect(avatar("grok").letter == nil)
        #expect(avatar("grok").normal == AgentAvatar.neutral.normal)
        #expect(avatar("mystery") == AgentAvatar.neutral)
    }
}
