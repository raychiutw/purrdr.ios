import Foundation

/// Claude 方案用量(行為規格 F18):5 小時與每週視窗已用的比例與重置時間。
public struct ClaudeUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// 已用比例，0～100。
        public var usedPercentage: Double
        public var resetsAt: Date?

        public init(usedPercentage: Double, resetsAt: Date?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public var fiveHour: Window?
    public var week: Window?
    /// 包裝腳本存下這份用量的時間。
    public var capturedAt: Date

    public init(fiveHour: Window?, week: Window?, capturedAt: Date) {
        self.fiveHour = fiveHour
        self.week = week
        self.capturedAt = capturedAt
    }
}

public enum ClaudeUsageError: Error, Equatable {
    /// `~/.claude/settings.json` 不是合法 JSON 物件，不能安全地修改。
    case settingsNotJSON
    /// 主機上沒有 `~/.claude`(沒裝 Claude Code)。
    case claudeNotFound
}

/// 用量檢查的結果。
public struct ClaudeUsageInspection: Equatable, Sendable {
    /// 會以這個主機使用者修改設定。
    public var user: String
    public var isInstalled: Bool
}

