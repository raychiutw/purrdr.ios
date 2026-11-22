import Foundation

/// Agent 設定檔的對話紀錄組(ADR-0013):位置規則、逐行解析、header 的中繼資料、進度(context 與待辦)、slash 選單與 subagent 支援。
/// 沒有這一組的 Agent 沒有可讀的對話紀錄(畫面顯示不支援)。
///
/// 方言是常數表,以 `name` 為身分(同一份方言可以給多種 Agent 用,例如 Pi 與 OMP)。
public struct TranscriptDialect: Sendable, Equatable, Hashable {
    /// 方言的驗證狀態(每組記錄驗證過的 Agent 版本)。
    public enum Verification: Sendable, Equatable {
        /// 已用真實主機的資料驗證過(契約測試的 fixture 來源)。
        case verified(agentVersion: String)
        /// 依文件撰寫、**未實測**;`documentedFor` 是文件描述的 Agent 版本。
        case unverified(documentedFor: String)
    }

    public let name: String
    public let verification: Verification
    /// 以 session id 定位的位置規則。
    public let locator: TranscriptLocator
    /// 接受路徑參照(integration 以路徑回報,agy、Pi、OMP)時的位置規則;`nil` 表示只接受 id。
    public let reportedPathLocator: TranscriptLocator?
    public let slashMenu: SlashMenuSource
    /// 有 subagent、workflow 與背景 agents 窗格(Claude Code)。
    public let supportsSubagents: Bool
    /// 有 status line 的 session 狀態檔可讀(Claude Code,#388)。
    public let readsSessionStatus: Bool
    private let parseLine: @Sendable (String) -> [TranscriptMessage]
    private let applyMetadata: @Sendable (inout TranscriptMetadata, String) -> Void
    /// 以一行更新進度(context 與待辦);`nil` 表示這種方言沒有進度資料。第二個參數是已解析的 JSON 物件。
    private let applyProgress: (@Sendable (inout AgentProgress, [String: Any], String) -> Void)?

    public var isVerified: Bool {
        if case .verified = verification { true } else { false }
    }

    init(
        name: String, verification: Verification, locator: TranscriptLocator, reportedPathLocator: TranscriptLocator? = nil,
        slashMenu: SlashMenuSource = .none, supportsSubagents: Bool = false, readsSessionStatus: Bool = false,
        parseLine: @escaping @Sendable (String) -> [TranscriptMessage],
        applyMetadata: @escaping @Sendable (inout TranscriptMetadata, String) -> Void,
        applyProgress: (@Sendable (inout AgentProgress, [String: Any], String) -> Void)? = nil
    ) {
        self.name = name
        self.verification = verification
        self.locator = locator
        self.reportedPathLocator = reportedPathLocator
        self.slashMenu = slashMenu
        self.supportsSubagents = supportsSubagents
        self.readsSessionStatus = readsSessionStatus
        self.parseLine = parseLine
        self.applyMetadata = applyMetadata
        self.applyProgress = applyProgress
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    /// 解析一行。看不懂的行(通常是被截斷的尾行)回傳空陣列。
    public func messages(in line: String) -> [TranscriptMessage] { parseLine(line) }

    /// 以一行更新 header 中繼資料(較晚的值覆蓋較早的)。
    public func updateMetadata(_ metadata: inout TranscriptMetadata, with line: String) { applyMetadata(&metadata, line) }

    public func latestMetadata(in lines: [String]) -> TranscriptMetadata {
        var metadata = TranscriptMetadata()
        for line in lines { updateMetadata(&metadata, with: line) }
        return metadata
    }

    func updateProgress(_ progress: inout AgentProgress, object: [String: Any], line: String) {
        applyProgress?(&progress, object, line)
    }

    /// herdr 回報的 session 參照(`kind` 是 `id` 或 `path`)→ 位置;這種方言不接受該種參照時為 `nil`。
    public func location(kind: String, value: String, cwd: String) -> TranscriptLocation? {
        switch kind {
        case "id": TranscriptLocation(locator: locator, reference: .id(value), cwd: locator.usesProjectFolder ? cwd : "")
        case "path": reportedPathLocator.map { TranscriptLocation(locator: $0, reference: .path(value)) }
        default: nil
        }
    }
}

extension TranscriptDialect {
    /// Claude Code JSONL(§4.1)。
    public static let claude = TranscriptDialect(
        name: "claude", verification: .verified(agentVersion: "Claude Code 2.1.300–2.1.323"), locator: .claude,
        slashMenu: .discovered, supportsSubagents: true, readsSessionStatus: true,
        parseLine: { ClaudeTranscriptParser.messages(in: $0) },
        applyMetadata: { $0.update(with: $1) },
        applyProgress: { progress, object, line in progress.updateClaude(object, line: line) }
    )

    /// Grok 的 ACP `session/update` log(§4.3)。【未實測】
    public static let grok = TranscriptDialect(
        name: "grok", verification: .unverified(documentedFor: "Grok 1.0.52"), locator: .grok,
        slashMenu: .fixed(SlashMenuSource.grokCommands),
        parseLine: { GrokTranscriptParser.messages(in: $0) },
        applyMetadata: { GrokTranscriptParser.updateMetadata(&$0, with: $1) }
    )

    /// Antigravity(`agy`)的 step JSONL(§4.4)。
    public static let antigravity = TranscriptDialect(
        name: "antigravity", verification: .verified(agentVersion: "Antigravity CLI 1.5.14"), locator: .antigravity,
        reportedPathLocator: .reportedPath(),
        slashMenu: .fixed(SlashMenuSource.antigravityCommands),
        parseLine: { AntigravityTranscriptParser.messages(in: $0) },
        applyMetadata: { AntigravityTranscriptParser.updateMetadata(&$0, with: $1) }
    )

    /// Pi 與 OMP 共用的 journal(§4.5)。【未實測】
    public static let piJournal = TranscriptDialect(
        name: "pi-journal", verification: .unverified(documentedFor: "Pi coding-agent session format"), locator: .piJournal,
        reportedPathLocator: .reportedPath(headerCheck: TranscriptLocator.piJournal.headerCheck),
        parseLine: { PiJournalParser.messages(in: $0) },
        applyMetadata: { PiJournalParser.updateMetadata(&$0, with: $1) }
    )

    /// Codex 的 rollout JSONL(§4.2)。【未實測】
    public static let codex = TranscriptDialect(
        name: "codex", verification: .unverified(documentedFor: "Codex 0.157–0.163"), locator: .codex,
        slashMenu: .fixed(SlashMenuSource.codexCommands),
        parseLine: { CodexTranscriptParser.messages(in: $0) },
        applyMetadata: { CodexTranscriptParser.updateMetadata(&$0, with: $1) },
        applyProgress: { progress, object, _ in progress.updateCodex(object) }
    )

    /// 全部的方言(契約測試逐一檢查)。
    public static let all: [TranscriptDialect] = [.claude, .grok, .antigravity, .piJournal, .codex]
}
