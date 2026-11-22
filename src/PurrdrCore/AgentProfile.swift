/// Agent 種類(GLOSSARY「Agent 種類」、ADR-0013):herdr 認得的全部種類，正式名稱與別名照 herdr 的偵測程式
/// (`src/detect/mod.rs` 的 `agent_label`／`lookup_agent`)。herdr 回報的字串**只在這裡**轉成種類;
/// 核心以外不要直接比對 Agent 字串,一律問 `AgentCatalog` 的設定檔。認不得的是 `.other(原文)`。
public enum AgentID: Hashable, Sendable {
    case pi, claude, codex, gemini, cursor, devin, agy, cline, omp, mastracode, opencode, copilot
    case kimi, kiro, droid, amp, grok, hermes, kilo, qodercli, qwen, letta, maki, muse
    case other(String)

    /// herdr 認得的種類(不含 `.other`)。
    public static let allCases: [AgentID] = [
        .pi, .claude, .codex, .gemini, .cursor, .devin, .agy, .cline, .omp, .mastracode, .opencode, .copilot,
        .kimi, .kiro, .droid, .amp, .grok, .hermes, .kilo, .qodercli, .qwen, .letta, .maki, .muse,
    ]

    /// herdr 回報的 `agent` 字串 → 種類。正式名稱、herdr 的別名，以及舊版 Purrdr 誤用的 `open_code`、`github_copilot` 都認得。
    public init(herdrName: String) {
        self = Self.byName[herdrName] ?? .other(herdrName)
    }

    /// herdr 的正式名稱;其他種類是原文。
    public var canonicalName: String {
        switch self {
        case .pi: "pi"
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .cursor: "cursor"
        case .devin: "devin"
        case .agy: "agy"
        case .cline: "cline"
        case .omp: "omp"
        case .mastracode: "mastracode"
        case .opencode: "opencode"
        case .copilot: "copilot"
        case .kimi: "kimi"
        case .kiro: "kiro"
        case .droid: "droid"
        case .amp: "amp"
        case .grok: "grok"
        case .hermes: "hermes"
        case .kilo: "kilo"
        case .qodercli: "qodercli"
        case .qwen: "qwen"
        case .letta: "letta"
        case .maki: "maki"
        case .muse: "muse"
        case .other(let raw): raw
        }
    }

    /// 別名 → 種類(照 herdr `lookup_agent`;含舊版 Purrdr 的誤用拼法)。正式名稱由 `allCases` 補進。
    private static let aliases: [String: AgentID] = [
        "claude-code": .claude,
        "cursor-agent": .cursor,
        "devin-cli": .devin, "devin cli": .devin,
        "antigravity": .agy, "antigravity-cli": .agy,
        ".cline": .cline,
        "mastra-code": .mastracode, "mastra code": .mastracode,
        "opencode2": .opencode, "open-code": .opencode, "open_code": .opencode,
        "github-copilot": .copilot, "ghcs": .copilot, "github_copilot": .copilot,
        "kimi-code": .kimi, "kimi code": .kimi,
        "kiro-cli": .kiro,
        "amp-local": .amp,
        "grok-build": .grok,
        "hermes-agent": .hermes,
        "kilo-code": .kilo, "kilo code": .kilo,
        "qoderclicn": .qodercli, "qoder": .qodercli, "qodercn": .qodercli,
        "qwen-code": .qwen, "qwen code": .qwen,
        "letta-code": .letta, "letta code": .letta,
        "muse-code": .muse, "muse-cli": .muse,
    ]

    private static let byName: [String: AgentID] = {
        var table = aliases
        for id in allCases { table[id.canonicalName] = id }
        return table
    }()
}

/// 頭像的底色與字母(深淺色共用同一個底色，高對比時更深)。只放 RGB 值，畫面層再轉成顏色。
public struct AgentAvatar: Equatable, Sendable {
    public typealias Color = ThemeColor

    /// 頭像字母;`nil` 時取顯示名稱的首字母。
    public let letter: String?
    public let normal: Color
    public let highContrast: Color

    public init(letter: String?, normal: Color, highContrast: Color) {
        self.letter = letter
        self.normal = normal
        self.highContrast = highContrast
    }

    /// 沒有專屬配色的種類:中性色。
    public static let neutral = AgentAvatar(
        letter: nil, normal: Color(red: 0x5A, green: 0x5A, blue: 0x5F), highContrast: Color(red: 0x50, green: 0x50, blue: 0x55)
    )
}

/// 設定檔的顯示組:名稱、SF Symbol、頭像。
public struct AgentPresentation: Equatable, Sendable {
    /// 顯示名稱;沒有種類(空字串)時 `nil`。
    public let displayName: String?
    /// 列左側的 SF Symbol。SF Symbols 沒有各家商標，所以用形狀不同的通用符號。
    public let symbolName: String
    public let avatar: AgentAvatar

    public init(displayName: String?, symbolName: String, avatar: AgentAvatar = .neutral) {
        self.displayName = displayName
        self.symbolName = symbolName
        self.avatar = avatar
    }
}

/// Agent 設定檔(ADR-0013)。目前有顯示、對話紀錄、輸入與畫面組;session 組由後續票加入。
/// 沒有的那組是 `nil`,表示那項功能不提供。
public struct AgentProfile: Equatable, Sendable {
    public let id: AgentID
    public let presentation: AgentPresentation
    /// 對話紀錄組:沒有可讀的對話紀錄的 Agent 為 `nil`。
    public let transcript: TranscriptDialect?
    /// 輸入組:每種 Agent 都有(通用設定檔是不當 slash、沒有回答方式)。
    public let input: InputDialect
    /// 畫面組:從 pane 畫面讀面板、權限模式、建議(通用設定檔什麼都不讀)。
    public let screen: ScreenDialect

    public init(id: AgentID, presentation: AgentPresentation, transcript: TranscriptDialect? = nil, input: InputDialect, screen: ScreenDialect = .generic) {
        self.id = id
        self.presentation = presentation
        self.transcript = transcript
        self.input = input
        self.screen = screen
    }
}

/// Agent 設定檔目錄:依種類回傳設定檔,認不得的種類回通用設定檔(照原文顯示、中性頭像)。
public enum AgentCatalog {
    public static func profile(for id: AgentID) -> AgentProfile {
        AgentProfile(id: id, presentation: presentation(for: id), transcript: transcript(for: id), input: input(for: id), screen: screen(for: id))
    }

    private static func screen(for id: AgentID) -> ScreenDialect {
        switch id {
        case .claude: .claude
        case .codex: .codex
        default: .generic
        }
    }

    private static func input(for id: AgentID) -> InputDialect {
        switch id {
        case .claude: .claude
        case .codex: .codex
        case .agy: .antigravity
        case .grok: .grok
        case .pi, .omp: .piJournal
        default: .generic
        }
    }

    private static func transcript(for id: AgentID) -> TranscriptDialect? {
        switch id {
        case .claude: .claude
        case .codex: .codex
        case .grok: .grok
        case .agy: .antigravity
        case .pi, .omp: .piJournal
        default: nil
        }
    }

    /// 直接從 herdr 的字串取設定檔(轉換只在 `AgentID`)。
    public static func profile(forHerdrName name: String) -> AgentProfile {
        profile(for: AgentID(herdrName: name))
    }

    private static func color(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> AgentAvatar.Color {
        AgentAvatar.Color(red: red, green: green, blue: blue)
    }

    private static func presentation(for id: AgentID) -> AgentPresentation {
        switch id {
        case .claude:
            AgentPresentation(displayName: "Claude Code", symbolName: "sparkle", avatar: AgentAvatar(letter: "C", normal: color(0x8A, 0x5A, 0x48), highContrast: color(0x6D, 0x47, 0x39)))
        case .codex:
            AgentPresentation(displayName: "Codex", symbolName: "chevron.left.forwardslash.chevron.right", avatar: AgentAvatar(letter: "X", normal: color(0x55, 0x56, 0x5C), highContrast: color(0x4F, 0x50, 0x56)))
        case .gemini:
            AgentPresentation(displayName: "Gemini", symbolName: "star", avatar: AgentAvatar(letter: "G", normal: color(0x4A, 0x5F, 0x86), highContrast: color(0x3E, 0x50, 0x71)))
        case .opencode:
            AgentPresentation(displayName: "opencode", symbolName: "curlybraces", avatar: AgentAvatar(letter: "O", normal: color(0x5C, 0x6B, 0x4A), highContrast: color(0x48, 0x53, 0x3A)))
        case .copilot:
            AgentPresentation(displayName: "GitHub Copilot", symbolName: "airplane", avatar: AgentAvatar(letter: "P", normal: color(0x6A, 0x58, 0x84), highContrast: color(0x58, 0x49, 0x6E)))
        case .grok: AgentPresentation(displayName: "Grok", symbolName: "bolt")
        case .agy: AgentPresentation(displayName: "Antigravity", symbolName: "arrow.up.forward.circle")
        case .pi: AgentPresentation(displayName: "Pi", symbolName: "function")
        case .omp: AgentPresentation(displayName: "OMP", symbolName: "hexagon")
        case .cline: AgentPresentation(displayName: "Cline", symbolName: "line.diagonal")
        case .amp: AgentPresentation(displayName: "Amp", symbolName: "waveform")
        case .droid: AgentPresentation(displayName: "Droid", symbolName: "cpu")
        case .cursor: AgentPresentation(displayName: "Cursor", symbolName: "cursorarrow")
        case .devin: AgentPresentation(displayName: "Devin", symbolName: "person.crop.circle")
        case .mastracode: AgentPresentation(displayName: "Mastra Code", symbolName: "square.stack.3d.up")
        case .kimi: AgentPresentation(displayName: "Kimi", symbolName: "moon")
        case .kiro: AgentPresentation(displayName: "Kiro", symbolName: "k.circle")
        case .hermes: AgentPresentation(displayName: "Hermes", symbolName: "paperplane")
        case .kilo: AgentPresentation(displayName: "Kilo", symbolName: "scalemass")
        case .qodercli: AgentPresentation(displayName: "Qoder", symbolName: "qrcode")
        case .qwen: AgentPresentation(displayName: "Qwen", symbolName: "text.bubble")
        case .letta: AgentPresentation(displayName: "Letta", symbolName: "brain")
        case .maki: AgentPresentation(displayName: "Maki", symbolName: "circle.hexagongrid")
        case .muse: AgentPresentation(displayName: "Muse", symbolName: "music.note")
        case .other(let raw): AgentPresentation(displayName: raw.isEmpty ? nil : raw, symbolName: "terminal")
        }
    }
}
