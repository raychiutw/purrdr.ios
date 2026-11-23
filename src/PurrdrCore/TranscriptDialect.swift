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
    /// 一行 JSON 物件的種類(`type` 之類的判別欄位);只用來診斷「認不得的行」。
    private let lineKind: @Sendable ([String: Any]) -> String?
    /// 這份方言認得的行種類(含刻意不顯示的);其他種類在 `parse(_:)` 記為略過。
    private let knownKinds: Set<String>
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
        lineKind: @escaping @Sendable ([String: Any]) -> String? = { $0["type"] as? String }, knownKinds: Set<String>,
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
        self.lineKind = lineKind
        self.knownKinds = knownKinds
        self.parseLine = parseLine
        self.applyMetadata = applyMetadata
        self.applyProgress = applyProgress
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    /// 解析一行。看不懂的行(通常是被截斷的尾行)回傳空陣列。
    public func messages(in line: String) -> [TranscriptMessage] { parseLine(line) }

    /// 解析多行,並統計略過的行(部分失敗:認不得的行不讓整份失敗,只記下數量供診斷)。
    /// 空行不算;`skips` 只含種類名稱與行數,不含對話原文。
    public func parse(_ lines: [String]) -> TranscriptParse {
        var skips = TranscriptSkips()
        var messages: [TranscriptMessage] = []
        for line in lines where !line.isEmpty {
            let parsed = parseLine(line)
            messages += parsed
            guard parsed.isEmpty else { continue }
            guard let object = ClaudeTranscriptParser.jsonObject(line) else {
                skips.unparsableLines += 1
                continue
            }
            let kind = lineKind(object)
            if kind == nil || !knownKinds.contains(kind!) {
                skips.unknownKinds[TranscriptSkips.safeName(kind), default: 0] += 1
            }
        }
        return TranscriptParse(messages: messages, skips: skips)
    }

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
        knownKinds: ["assistant", "user", "attachment", "system", "last-prompt", "file-history-snapshot", "api-request-blob", "summary", "progress", "queue-operation", "custom-title", "agent-name", "ai-title", "permission-mode", "pr-link"],
        parseLine: { ClaudeTranscriptParser.messages(in: $0) },
        applyMetadata: { $0.update(with: $1) },
        applyProgress: { progress, object, line in progress.updateClaude(object, line: line) }
    )

    /// Grok 的 ACP `session/update` log(§4.3)。【未實測】
    public static let grok = TranscriptDialect(
        name: "grok", verification: .unverified(documentedFor: "Grok 1.0.52"), locator: .grok,
        slashMenu: .fixed(SlashMenuSource.grokCommands),
        lineKind: { (($0["params"] as? [String: Any])?["update"] as? [String: Any])?["sessionUpdate"] as? String },
        knownKinds: ["user_message_chunk", "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "plan", "available_commands_update", "current_mode_update"],
        parseLine: { GrokTranscriptParser.messages(in: $0) },
        applyMetadata: { GrokTranscriptParser.updateMetadata(&$0, with: $1) }
    )

    /// Antigravity(`agy`)的 step JSONL(§4.4)。
    public static let antigravity = TranscriptDialect(
        name: "antigravity", verification: .verified(agentVersion: "Antigravity CLI 1.5.14"), locator: .antigravity,
        reportedPathLocator: .reportedPath(),
        slashMenu: .fixed(SlashMenuSource.antigravityCommands), readsSessionStatus: true,
        knownKinds: ["USER_INPUT", "PLANNER_RESPONSE", "GENERIC", "SYSTEM_MESSAGE", "EPHEMERAL_MESSAGE"],
        parseLine: { AntigravityTranscriptParser.messages(in: $0) },
        applyMetadata: { AntigravityTranscriptParser.updateMetadata(&$0, with: $1) }
    )

    /// Pi 與 OMP 共用的 journal(§4.5)。【未實測】
    public static let piJournal = TranscriptDialect(
        name: "pi-journal", verification: .unverified(documentedFor: "Pi coding-agent session format"), locator: .piJournal,
        reportedPathLocator: .reportedPath(headerCheck: TranscriptLocator.piJournal.headerCheck),
        knownKinds: ["session", "model_change", "thinking_level_change", "message", "compaction", "branch_summary", "reset_boundary"],
        parseLine: { PiJournalParser.messages(in: $0) },
        applyMetadata: { PiJournalParser.updateMetadata(&$0, with: $1) }
    )

    /// Codex 的 rollout JSONL(§4.2)。【未實測】
    public static let codex = TranscriptDialect(
        name: "codex", verification: .unverified(documentedFor: "Codex 0.157–0.163"), locator: .codex,
        slashMenu: .fixed(SlashMenuSource.codexCommands),
        knownKinds: ["session_meta", "turn_context", "response_item", "event_msg", "compacted"],
        parseLine: { CodexTranscriptParser.messages(in: $0) },
        applyMetadata: { CodexTranscriptParser.updateMetadata(&$0, with: $1) },
        applyProgress: { progress, object, _ in progress.updateCodex(object) }
    )

    /// 全部的方言(契約測試逐一檢查)。
    public static let all: [TranscriptDialect] = [.claude, .grok, .antigravity, .piJournal, .codex]
}

/// `TranscriptDialect.parse(_:)` 的結果。
public struct TranscriptParse: Sendable {
    public let messages: [TranscriptMessage]
    public let skips: TranscriptSkips
}

/// 解析時略過的行(診斷用,不含對話原文)。
public struct TranscriptSkips: Sendable, Equatable {
    /// 不是 JSON 物件的行(多半是視窗邊界被切斷的第一行)。
    public var unparsableLines = 0
    /// 是 JSON 物件、但種類方言不認得的行(種類名稱 → 行數)。
    public var unknownKinds: [String: Int] = [:]

    public init() {}
    public var isEmpty: Bool { unparsableLines == 0 && unknownKinds.isEmpty }

    /// 種類名稱只留英數與 `_-.`、最長 40 字,避免把原文寫進紀錄。
    static func safeName(_ kind: String?) -> String {
        guard let kind, !kind.isEmpty else { return "(none)" }
        let allowed = kind.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) || "_-.".unicodeScalars.contains($0)) }
        return allowed ? String(kind.prefix(40)) : "(other)"
    }
}
