import Foundation

/// 對話紀錄的格式(行為規格 §4.0 的 Agent 表「讀取器」欄)。每種格式一個解析器，彼此獨立:換掉或新增一種
/// 不影響其他 agent。依 Agent 種類選格式(不依行的形狀猜)。
public enum TranscriptFormat: Sendable, Equatable, Hashable, Codable {
    /// Claude Code JSONL(§4.1)。
    case claude
    /// Grok 的 ACP `session/update` log(§4.3)。【未實測】
    case grok
    /// Antigravity(`agy`)的 step JSONL(§4.4)。【未實測】
    case antigravity
    /// Pi 與 OMP 共用的 journal(§4.5)。【未實測】
    case piJournal

    /// herdr 回報的 Agent 種類 → 格式;沒有可讀對話紀錄的種類回傳 `nil`。
    public init?(agentKind: String) {
        switch agentKind {
        case "claude": self = .claude
        case "grok": self = .grok
        case "agy": self = .antigravity
        case "pi", "omp": self = .piJournal
        default: return nil
        }
    }

    /// 解析器是否已在真實主機上驗證過。`false` 的格式是依文件撰寫、**未實測**。
    public var isVerified: Bool {
        self == .claude
    }

    /// 解析一行。看不懂的行(通常是被截斷的尾行)回傳空陣列。
    public func messages(in line: String) -> [TranscriptMessage] {
        switch self {
        case .claude: ClaudeTranscriptParser.messages(in: line)
        case .grok: GrokTranscriptParser.messages(in: line)
        case .antigravity: AntigravityTranscriptParser.messages(in: line)
        case .piJournal: PiJournalParser.messages(in: line)
        }
    }

    /// 以一行更新 header 中繼資料(較晚的值覆蓋較早的)。
    public func updateMetadata(_ metadata: inout TranscriptMetadata, with line: String) {
        switch self {
        case .claude: metadata.update(with: line)
        case .grok: GrokTranscriptParser.updateMetadata(&metadata, with: line)
        case .antigravity: AntigravityTranscriptParser.updateMetadata(&metadata, with: line)
        case .piJournal: PiJournalParser.updateMetadata(&metadata, with: line)
        }
    }

    public func latestMetadata(in lines: [String]) -> TranscriptMetadata {
        var metadata = TranscriptMetadata()
        for line in lines { updateMetadata(&metadata, with: line) }
        return metadata
    }
}
