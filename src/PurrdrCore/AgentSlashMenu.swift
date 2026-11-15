import Foundation

/// 一個 slash 指令(選單的一列)。
public struct SlashCommand: Sendable, Equatable, Hashable {
    /// 不含 `/` 的名稱。
    public var name: String
    /// 參數提示(例如 `<name>`、`[context]`);沒有參數時為 `nil`。以 `<` 開頭表示必填(行為規格 F9.3)。
    public var argumentHint: String?
    public var summary: String

    public init(name: String, argumentHint: String? = nil, summary: String) {
        self.name = name
        self.argumentHint = argumentHint
        self.summary = summary
    }
}

/// 某種 agent 打 `/` 時的選單來源(行為規格 F9.1、#37 G17)。
///
/// 這裡只是**資料來源**:選單畫面、篩選與挑選規則(F9.3)屬於 Slash 選單那張票(#15)。
public enum AgentSlashMenu: Sendable, Equatable {
    /// 沒有選單(Pi、OMP,以及其他 agent)。
    case none
    /// 固定清單(Grok、Antigravity)。【未實測】取自各自的官方文件，沒有在真實 agent 上比對過。
    case fixed([SlashCommand])
    /// 由主機上發現(Claude:內建、專案、使用者、plugin 指令;#15)。
    case discovered

    public init(agentKind: String) {
        switch agentKind {
        case "claude": self = .discovered
        case "grok": self = .fixed(Self.grok)
        case "agy": self = .fixed(Self.antigravity)
        default: self = .none
        }
    }

    /// Grok Build TUI 的指令(docs.x.ai/build/modes-and-commands,2026-11 取用)。別名不另列;
    /// 依功能開關才出現的(`/auto`、`/imagine`…)照列，由 Grok 自己拒絕。
    static let grok: [SlashCommand] = [
        // Session 與導覽
        SlashCommand(name: "help", summary: "Browse commands and keyboard shortcuts"),
        SlashCommand(name: "new", summary: "Start a new session"),
        SlashCommand(name: "resume", summary: "Reopen a previous session"),
        SlashCommand(name: "sessions", summary: "Switch, rename, or close active sessions"),
        SlashCommand(name: "fork", summary: "Branch the current session into a peer agent"),
        SlashCommand(name: "rename", argumentHint: "<title>", summary: "Rename the current session"),
        SlashCommand(name: "share", summary: "Get a URL to share the session"),
        SlashCommand(name: "session-info", summary: "Show session details"),
        SlashCommand(name: "home", summary: "Return to the welcome screen"),
        SlashCommand(name: "quit", summary: "Close the app"),
        // Context 與歷史
        SlashCommand(name: "context", summary: "Check context usage"),
        SlashCommand(name: "compact", argumentHint: "[context]", summary: "Compact conversation history"),
        SlashCommand(name: "rewind", summary: "Return to a previous turn"),
        SlashCommand(name: "export", summary: "Export the conversation to a file or the clipboard"),
        SlashCommand(name: "copy", argumentHint: "[N]", summary: "Copy the latest response, or the Nth-latest"),
        SlashCommand(name: "find", summary: "Search the conversation scrollback"),
        SlashCommand(name: "transcript", summary: "Open the full transcript in the pager"),
        // 模型與模式
        SlashCommand(name: "model", argumentHint: "<name>", summary: "Switch the active model"),
        SlashCommand(name: "effort", summary: "Set reasoning effort for the current model"),
        SlashCommand(name: "always-approve", summary: "Toggle always-approve mode"),
        SlashCommand(name: "auto", summary: "Toggle auto mode"),
        SlashCommand(name: "plan", argumentHint: "[description]", summary: "Enter plan mode"),
        SlashCommand(name: "view-plan", summary: "View the current plan"),
        // 任務與 agent
        SlashCommand(name: "btw", argumentHint: "<question>", summary: "Ask a side question without interrupting"),
        SlashCommand(name: "loop", argumentHint: "[interval] <prompt>", summary: "Run a prompt on a recurring interval"),
        SlashCommand(name: "imagine", argumentHint: "<prompt>", summary: "Generate an image from a description"),
        SlashCommand(name: "imagine-video", argumentHint: "<prompt>", summary: "Generate a video from a description"),
        SlashCommand(name: "tasks", summary: "List background tasks, subagents, and scheduled tasks"),
        SlashCommand(name: "create-workflow", argumentHint: "[description]", summary: "Author and save a workflow"),
        SlashCommand(name: "workflow", argumentHint: "<name> [args]", summary: "Launch or control a saved workflow"),
        SlashCommand(name: "workflows", summary: "Open the workflow run dashboard"),
        SlashCommand(name: "deep-research", argumentHint: "<query>", summary: "Run a background research workflow"),
        SlashCommand(name: "queue", summary: "List prompts queued behind the running turn"),
        SlashCommand(name: "dashboard", summary: "Open the Agent Dashboard"),
        SlashCommand(name: "config-agents", summary: "Manage agent definitions"),
        SlashCommand(name: "personas", summary: "Manage personas"),
        // 介面與設定
        SlashCommand(name: "settings", summary: "Open settings"),
        SlashCommand(name: "theme", argumentHint: "[name]", summary: "Switch the color theme"),
        SlashCommand(name: "compact-mode", summary: "Toggle a denser layout"),
        SlashCommand(name: "multiline", summary: "Toggle multiline input"),
        SlashCommand(name: "vim-mode", summary: "Toggle vim-style scrollback keys"),
        SlashCommand(name: "timestamps", argumentHint: "<mode>", summary: "Set clock display to off, minimal, or on"),
        SlashCommand(name: "density", argumentHint: "<level>", summary: "Set tool-call detail level"),
        SlashCommand(name: "terminal-setup", summary: "Check terminal and clipboard setup"),
        // 記憶、帳號、說明
        SlashCommand(name: "remember", argumentHint: "<note>", summary: "Save a memory note"),
        SlashCommand(name: "import-claude", summary: "Import Claude settings"),
        SlashCommand(name: "feedback", argumentHint: "[text]", summary: "Send feedback about the session"),
        SlashCommand(name: "release-notes", summary: "View release notes"),
        SlashCommand(name: "usage", summary: "View credit usage or manage billing"),
        SlashCommand(name: "privacy", summary: "Show or toggle privacy and data retention"),
        SlashCommand(name: "login", summary: "Sign in"),
        SlashCommand(name: "logout", summary: "Sign out"),
        // 擴充
        SlashCommand(name: "hooks", summary: "Manage hooks"),
        SlashCommand(name: "plugins", summary: "Manage plugins"),
        SlashCommand(name: "marketplace", summary: "Browse the marketplace"),
        SlashCommand(name: "skills", summary: "Manage skills"),
        SlashCommand(name: "mcps", summary: "Manage MCP servers"),
        // xai-grok-shell 提供
        SlashCommand(name: "goal", argumentHint: "<objective>", summary: "Work toward an objective until it is verified complete"),
        SlashCommand(name: "flush", summary: "Write conversation memory to disk now"),
        SlashCommand(name: "memory", summary: "Browse, view, and manage memories"),
        SlashCommand(name: "dream", summary: "Run memory consolidation"),
    ]

    /// Antigravity CLI(`agy`)的指令(antigravity.google/docs/features?tab=cli,2026-11 取用)。文件只為部分指令附
    /// 說明，其餘的說明是依名稱與文件內文寫的簡述。
    static let antigravity: [SlashCommand] = [
        SlashCommand(name: "help", summary: "Show commands and shortcuts"),
        SlashCommand(name: "model", summary: "Choose the model"),
        SlashCommand(name: "effort", summary: "Set reasoning effort"),
        SlashCommand(name: "plan", summary: "Plan before making changes"),
        SlashCommand(name: "goal", summary: "Work toward a goal until it is done"),
        SlashCommand(name: "context", summary: "Show context usage"),
        SlashCommand(name: "rewind", summary: "Rewind the conversation to an earlier checkpoint"),
        SlashCommand(name: "resume", summary: "Resume a conversation"),
        SlashCommand(name: "fork", argumentHint: "<project_id>", summary: "Fork the conversation into another project"),
        SlashCommand(name: "title", summary: "Customize the terminal title"),
        SlashCommand(name: "diff", summary: "Review workspace changes, commits, and per-turn changes"),
        SlashCommand(name: "agents", summary: "Monitor subagents and approve their requests"),
        SlashCommand(name: "tasks", summary: "Show background tasks"),
        SlashCommand(name: "schedule", summary: "Set a timer or recurring check in this conversation"),
        SlashCommand(name: "run-workflow", argumentHint: "<task>", summary: "Orchestrate many agents with a short script"),
        SlashCommand(name: "swarm", summary: "Run a swarm of agents"),
        SlashCommand(name: "teamwork", summary: "Work with a team of agents"),
        SlashCommand(name: "browser", summary: "Drive Chrome in an isolated subagent"),
        SlashCommand(name: "codesearch", summary: "Search the codebase"),
        SlashCommand(name: "btw", summary: "Ask a side question"),
        SlashCommand(name: "grill-me", summary: "Get questioned about your plan"),
        SlashCommand(name: "learn", summary: "Learn from this conversation"),
        SlashCommand(name: "permissions", summary: "Choose a permission preset"),
        SlashCommand(name: "projects", summary: "Create remote projects and attach resources"),
        SlashCommand(name: "plugin", summary: "Open the plugin manager"),
        SlashCommand(name: "agy-customizations", summary: "Manage customizations"),
        SlashCommand(name: "automation", summary: "Manage automations"),
        SlashCommand(name: "generative_ui", summary: "Toggle generative UI"),
        SlashCommand(name: "statusline", summary: "Customize the status line"),
        SlashCommand(name: "keybindings", summary: "Edit keyboard shortcuts"),
        SlashCommand(name: "voice", argumentHint: "[live|dictate]", summary: "Start voice mode or dictation"),
        SlashCommand(name: "record", summary: "Start dictation"),
        SlashCommand(name: "remote-control", argumentHint: "[off]", summary: "Turn Remote Control on or off"),
        SlashCommand(name: "boost", summary: "Boost this conversation"),
        SlashCommand(name: "usage", summary: "Show usage"),
        SlashCommand(name: "credits", summary: "Show credits"),
        SlashCommand(name: "changelog", summary: "Show what's new"),
        SlashCommand(name: "antigravity-guide", summary: "Open the Antigravity guide"),
    ]
}
