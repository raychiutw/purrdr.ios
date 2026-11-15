import Foundation

/// slash 選單一個分組的來源(#15「依來源分組」)。
public enum SlashSource: Sendable, Hashable {
    /// agent 自己的內建指令。
    case builtIn
    /// 專案層 `<cwd>/.claude/skills`、`<cwd>/.claude/commands`。
    case project
    /// 使用者層 `~/.claude/skills`、`~/.claude/commands`。
    case user
    /// 某個 plugin(名稱取自它的 `plugin.json`)。
    case plugin(String)
    /// 只出現在 session 的 `skill_listing`、在主機上找不到出處的 skill(例如 Claude Code 自帶的)。
    case session

    /// 去重的優先序(行為規格 F9.1:內建 > 專案 > 使用者 > plugin > 其他)。數字小的先。
    var rank: Int {
        switch self {
        case .builtIn: 0
        case .project: 1
        case .user: 2
        case .plugin: 3
        case .session: 4
        }
    }
}

/// slash 選單的一個分組。
public struct SlashSection: Sendable, Equatable, Identifiable {
    public var source: SlashSource
    public var commands: [SlashCommand]

    public var id: SlashSource { source }

    public init(source: SlashSource, commands: [SlashCommand]) {
        self.source = source
        self.commands = commands
    }
}

/// 某個 agent 的完整 slash 清單。
public struct SlashCatalog: Sendable, Equatable {
    public var sections: [SlashSection]
    /// 發現沒有在時間上限內做完(或某一步失敗):清單不完整，不能當成完整清單。
    public var isComplete: Bool

    public init(sections: [SlashSection], isComplete: Bool) {
        self.sections = sections
        self.isComplete = isComplete
    }

    public static let empty = SlashCatalog(sections: [], isComplete: true)

    /// 固定清單(Grok、Antigravity)只有一個「內建」分組。
    public init(fixed commands: [SlashCommand]) {
        self.init(sections: [SlashSection(source: .builtIn, commands: commands)], isComplete: true)
    }

    /// 依來源合併：同名指令只留優先序最高的來源(F9.1);分組順序為內建、專案、使用者、plugin(依名稱)、其他。
    /// 每組內依名稱排序。說明空白時，用同名的其他來源(例如 `skill_listing`)補上。
    static func merged(_ entries: [(source: SlashSource, command: SlashCommand)], isComplete: Bool) -> SlashCatalog {
        var best: [String: (source: SlashSource, command: SlashCommand)] = [:]
        var summaries: [String: String] = [:]
        for entry in entries {
            let name = entry.command.name
            if !entry.command.summary.isEmpty, summaries[name] == nil { summaries[name] = entry.command.summary }
            if let current = best[name], current.source.rank <= entry.source.rank { continue }
            best[name] = entry
        }
        var grouped: [SlashSource: [SlashCommand]] = [:]
        for (name, entry) in best {
            var command = entry.command
            if command.summary.isEmpty { command.summary = summaries[name] ?? "" }
            grouped[entry.source, default: []].append(command)
        }
        let sections = grouped
            .map { SlashSection(source: $0.key, commands: $0.value.sorted { $0.name < $1.name }) }
            .sorted { lhs, rhs in
                if lhs.source.rank != rhs.source.rank { return lhs.source.rank < rhs.source.rank }
                if case .plugin(let left) = lhs.source, case .plugin(let right) = rhs.source { return left < right }
                return false
            }
        return SlashCatalog(sections: sections, isComplete: isComplete)
    }
}
