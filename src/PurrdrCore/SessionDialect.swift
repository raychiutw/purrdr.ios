import Foundation

/// Agent 設定檔的 session 組(ADR-0013、#442):新聊天(種類與啟動參數)、恢復舊 session、session 標題規則。
///
/// 方言是常數表,以 `name` 為身分。session 狀態(status line、context、model／effort)在對話紀錄組
/// (`TranscriptDialect.readsSessionStatus`)與畫面組。
public struct SessionDialect: Sendable, Equatable {
    public typealias Verification = TranscriptDialect.Verification

    /// session 標題從 herdr 回報的欄位取哪一個、怎麼整理。
    public enum TitleRule: Sendable, Equatable {
        /// herdr 的 `title`,沒有才用終端機標題。
        case sessionTitleThenTerminal
        /// Codex:`title` 是被截斷的第一個 prompt;真正的名稱是終端機標題去掉結尾「 | 資料夾」。
        case terminalTitleBeforeFolderSuffix
        /// Grok:終端機標題取「 - grok」前一段,去掉前導 spinner 與「Action Required」。
        case grokTerminalTitle
    }

    public let name: String
    public let verification: Verification
    /// app 能開新聊天(`herdr agent start --kind <正式名稱>`)。
    public let startsNewChat: Bool
    /// 啟動時帶權限模式的旗標(Claude Code 的 `--permission-mode`);`nil` 表示沒有這個選項。
    public let permissionModeFlag: String?
    /// 主機服務列出與恢復過去 session 的種類;`nil` 表示不能恢復。
    public let resumeKind: String?
    public let titleRule: TitleRule

    init(
        name: String, verification: Verification, startsNewChat: Bool = false, permissionModeFlag: String? = nil,
        resumeKind: String? = nil, titleRule: TitleRule = .sessionTitleThenTerminal
    ) {
        self.name = name
        self.verification = verification
        self.startsNewChat = startsNewChat
        self.permissionModeFlag = permissionModeFlag
        self.resumeKind = resumeKind
        self.titleRule = titleRule
    }

    /// Session 標題:哪個欄位才是標題依規則而定;預設終端機標題、resume 指令、像 session id 的字串都不算。
    public func title(sessionTitle: String?, terminalTitle: String?) -> String? {
        let candidate: String? = switch titleRule {
        case .sessionTitleThenTerminal: sessionTitle ?? terminalTitle
        case .terminalTitleBeforeFolderSuffix:
            terminalTitle.flatMap { title in
                title.range(of: " | ", options: .backwards).map { String(title[..<$0.lowerBound]) }
            }
        case .grokTerminalTitle: terminalTitle.map(Self.grokTitle)
        }
        guard let title = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              !Self.isDefaultTerminalTitle(title) else { return nil }
        return title
    }

    private static func grokTitle(_ terminalTitle: String) -> String {
        var title = terminalTitle
        if let suffix = title.range(of: " - grok", options: [.backwards, .caseInsensitive]) {
            title = String(title[..<suffix.lowerBound])
        }
        title = title.replacingOccurrences(of: "Action Required", with: "")
        return String(title.drop { !$0.isLetter && !$0.isNumber })
    }

    private static let defaultTitles: Set<String> = ["claude code", "claude", "codex", "grok", "omp", "agy"]

    private static func isDefaultTerminalTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        if defaultTitles.contains(lowered) { return true }
        if lowered.contains("--resume") || lowered.contains("--continue") || lowered.hasPrefix("codex resume") { return true }
        // 含 UUID 片段(8-4 位十六進位)的多半是 session id。
        return lowered.contains(/[0-9a-f]{8}-[0-9a-f]{4}/)
    }
}

extension SessionDialect {
    static let claude = SessionDialect(
        name: "claude", verification: .verified(agentVersion: "Claude Code 2.1.300–2.1.325"), startsNewChat: true,
        permissionModeFlag: "--permission-mode", resumeKind: "claude"
    )
    static let codex = SessionDialect(
        name: "codex", verification: .verified(agentVersion: "Codex 0.157–0.163"), startsNewChat: true, resumeKind: "codex",
        titleRule: .terminalTitleBeforeFolderSuffix
    )
    static let grok = SessionDialect(
        name: "grok", verification: .unverified(documentedFor: "Grok 1.0.52"), startsNewChat: true, titleRule: .grokTerminalTitle
    )
    /// Antigravity:能開新聊天;恢復(`agy --conversation <id>`)之後再加。
    static let antigravity = SessionDialect(
        name: "antigravity", verification: .verified(agentVersion: "Antigravity CLI 1.5.14"), startsNewChat: true
    )
    static let piJournal = SessionDialect(
        name: "pi-journal", verification: .unverified(documentedFor: "Pi coding-agent"), startsNewChat: true
    )
    /// 其他種類:不能開新聊天、不能恢復;標題照 herdr 回報。
    public static let generic = SessionDialect(name: "generic", verification: .unverified(documentedFor: "none"))
}

extension AgentID {
    /// 主機服務能恢復過去 session 的種類。
    public var supportsResume: Bool { AgentCatalog.profile(for: self).session.resumeKind != nil }
}
