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

/// 某種 agent 打 `/` 時的選單來源(Agent 設定檔對話紀錄組的 `slashMenu`)(行為規格 F9.1、#37 G17)。
///
/// 這裡只是**資料來源**:選單畫面、篩選與挑選規則(F9.3)屬於 Slash 選單那張票(#15)。
public enum SlashMenuSource: Sendable, Equatable {
    /// 沒有選單(Pi、OMP,以及其他 agent)。
    case none
    /// 固定清單(Grok、Antigravity、Codex)。Antigravity 取自 agy 1.5.14 真實 `/help`;Grok、Codex【未實測】取自各自的官方文件。
    case fixed([SlashCommand])
    /// 由主機上發現(Claude:內建、專案、使用者、plugin 指令;#15)。
    case discovered

    /// Grok Build TUI 的指令(docs.x.ai/build/modes-and-commands,2026-11 取用)。別名不另列;
    /// 依功能開關才出現的(`/auto`、`/imagine`…)照列，由 Grok 自己拒絕。
    static let grokCommands: [SlashCommand] = [
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

    /// Antigravity CLI(`agy`)的指令:agy 1.5.14 真實 `/help` 的 commands 分頁(共 51 項,`screens/agy-help-commands-{1,2,3}.txt`,#445),
    /// 依 `/help` 的順序。第 21 項在錄到的三頁之間被捲掉,依官方文件補 `mcp`。說明是照 `/help` 縮短的簡述;別名(`quit`、`new`…)不另列。
    static let antigravityCommands: [SlashCommand] = [
        SlashCommand(name: "add-dir", summary: "Add a directory to the workspace"),
        SlashCommand(name: "agents", summary: "List available custom agents"),
        SlashCommand(name: "artifact", summary: "View and review artifacts"),
        SlashCommand(name: "btw", summary: "Ask a side question without interrupting the current task"),
        SlashCommand(name: "changelog", summary: "Show release notes and changes"),
        SlashCommand(name: "clear", summary: "Clear conversation and start a new one"),
        SlashCommand(name: "codesearch", argumentHint: "<query>", summary: "Search code in the workspace"),
        SlashCommand(name: "config", summary: "Open settings panel"),
        SlashCommand(name: "context", summary: "Visualize current context usage"),
        SlashCommand(name: "copy", argumentHint: "[n|btw]", summary: "Copy the last planner response to the clipboard"),
        SlashCommand(name: "credits", summary: "Show remaining G1 credits and purchase link"),
        SlashCommand(name: "diff", summary: "View uncommitted changes and per-turn diffs"),
        SlashCommand(name: "effort", summary: "Set the reasoning effort"),
        SlashCommand(name: "exit", summary: "Exit the CLI"),
        SlashCommand(name: "feedback", summary: "Submit qualitative feedback to improve the agent"),
        SlashCommand(name: "fork", argumentHint: "[project_id]", summary: "Create a branch of the current conversation at this point"),
        SlashCommand(name: "help", summary: "Show available commands and keybindings"),
        SlashCommand(name: "hooks", summary: "Manage hook configurations for tool events"),
        SlashCommand(name: "keybindings", summary: "Set custom keybindings"),
        SlashCommand(name: "logout", summary: "Log out"),
        SlashCommand(name: "mcp", summary: "Manage MCP servers"),
        SlashCommand(name: "model", summary: "Set a model, or run a single prompt on another model"),
        SlashCommand(name: "open", summary: "Open a file or view opened/edited files"),
        SlashCommand(name: "permissions", summary: "Manage tool permissions"),
        SlashCommand(name: "plugin", summary: "Manage, discover, install, uninstall, enable, and disable plugins"),
        SlashCommand(name: "projects", summary: "Create and edit projects"),
        SlashCommand(name: "record", summary: "Dictate a prompt using your microphone"),
        SlashCommand(name: "remote-control", argumentHint: "[off]", summary: "Turn on remote control for this session"),
        SlashCommand(name: "rename", summary: "Rename the current conversation"),
        SlashCommand(name: "resume", summary: "Browse and resume past conversations"),
        SlashCommand(name: "rewind", summary: "Rewind conversation to a previous message"),
        SlashCommand(name: "skills", summary: "List available skills"),
        SlashCommand(name: "statusline", summary: "Toggle the statusline"),
        SlashCommand(name: "tasks", summary: "View background tasks"),
        SlashCommand(name: "thinking", summary: "Toggle streaming the model's full thinking in the transcript"),
        SlashCommand(name: "title", summary: "Toggle custom terminal window title"),
        SlashCommand(name: "usage", summary: "View model quota usage"),
        SlashCommand(name: "voice", summary: "Dictate a prompt or talk with the agent by voice"),
        SlashCommand(name: "goal", summary: "Run until the specified goal is completely finished"),
        SlashCommand(name: "compact", summary: "Compact the conversation now to free up the context window"),
        SlashCommand(name: "schedule", summary: "Run an instruction on a recurring schedule or as a one-time timer"),
        SlashCommand(name: "browser", summary: "Invoke a browser agent for web tasks"),
        SlashCommand(name: "plan", summary: "Plan carefully before executing a task"),
        SlashCommand(name: "grill-me", summary: "Interview me to align on a plan"),
        SlashCommand(name: "teamwork", summary: "Invoke a team of agents to tackle large projects"),
        SlashCommand(name: "learn", summary: "Reflect on recent successes or corrections to capture reusable skills or rules"),
        SlashCommand(name: "boost", summary: "Invoke the Boost multi-agent orchestrator for complex tasks"),
        SlashCommand(name: "agy-customizations", summary: "Guide and reference for the Antigravity customization system"),
        SlashCommand(name: "antigravity-guide", summary: "Guide, quick reference, and sitemap for Google Antigravity"),
        SlashCommand(name: "run-workflow", summary: "Write and run a dynamic workflow script that orchestrates many agents"),
        SlashCommand(name: "swarm", summary: "Run several agents in parallel on one task (preview, quota heavy)"),
    ]

    /// Codex TUI 的內建指令(openai/codex `codex-rs/tui/src/slash_command.rs`,2026-11-16 取用;官方文件的
    /// slash 指令頁已改版、目前沒有 CLI 清單)。依原始碼的宣告順序(也是 Codex 選單的順序);說明取自 `description()`,
    /// 句首改大寫。只在 debug build 出現的(`rollout`、`test-approval`、`debug-m-*`)不列;依平台或功能開關才出現的照列，
    /// 由 Codex 自己拒絕。別名(`cwd`、`pet`、`clean`)不另列。
    static let codexCommands: [SlashCommand] = [
        SlashCommand(name: "model", summary: "Choose what model and reasoning effort to use"),
        SlashCommand(name: "presets", summary: "Run or save reusable prompts and slash commands"),
        SlashCommand(name: "daybreak", summary: "Turn Daybreak on or off"),
        SlashCommand(name: "ide", summary: "Include current selection, open files, and other context from your IDE"),
        SlashCommand(name: "permissions", summary: "Choose what Codex is allowed to do"),
        SlashCommand(name: "keymap", summary: "Remap TUI shortcuts"),
        SlashCommand(name: "vim", summary: "Toggle Vim mode for the composer"),
        SlashCommand(name: "setup-default-sandbox", summary: "Set up elevated agent sandbox"),
        SlashCommand(name: "experimental", summary: "Toggle experimental features"),
        SlashCommand(name: "approve", summary: "Approve one retry of a recent auto-review denial"),
        SlashCommand(name: "memories", summary: "Configure memory use and generation"),
        SlashCommand(name: "skills", summary: "Use skills to improve how Codex performs specific tasks"),
        SlashCommand(name: "import", summary: "Import setup, this project, and recent chats from Claude Code"),
        SlashCommand(name: "hooks", summary: "View and manage lifecycle hooks"),
        SlashCommand(name: "review", summary: "Review my current changes and find issues"),
        SlashCommand(name: "rename", summary: "Rename the current thread"),
        SlashCommand(name: "new", summary: "Start a new chat during a conversation"),
        SlashCommand(name: "archive", summary: "Archive this session"),
        SlashCommand(name: "delete", summary: "Permanently delete this session"),
        SlashCommand(name: "resume", summary: "Resume a saved chat"),
        SlashCommand(name: "fork", summary: "Fork the current chat"),
        SlashCommand(name: "worktree", summary: "Start or continue a conversation in a new worktree"),
        SlashCommand(name: "app", summary: "Continue this session in the Desktop app"),
        SlashCommand(name: "init", summary: "Create an AGENTS.md file with instructions for Codex"),
        SlashCommand(name: "compact", summary: "Summarize conversation to prevent hitting the context limit"),
        SlashCommand(name: "config", summary: "Configure Codex preferences"),
        SlashCommand(name: "recap", summary: "Summarize the current conversation now"),
        SlashCommand(name: "plan", summary: "Switch to Plan mode"),
        SlashCommand(name: "voice", summary: "Start or stop voice"),
        SlashCommand(name: "goal", summary: "Set or view the goal for a long-running task"),
        SlashCommand(name: "agents", summary: "Open the agent command center"),
        SlashCommand(name: "side", summary: "Start a side conversation"),
        SlashCommand(name: "btw", summary: "Start a side conversation"),
        SlashCommand(name: "copy", summary: "Copy the last response or part of it"),
        SlashCommand(name: "export", summary: "Export the conversation as Markdown"),
        SlashCommand(name: "raw", summary: "Toggle raw scrollback mode for copy-friendly terminal selection"),
        SlashCommand(name: "tui", summary: "Choose the TUI mode for the next launch"),
        SlashCommand(name: "diff", summary: "Show git diff (including untracked files)"),
        SlashCommand(name: "mention", summary: "Mention a file"),
        SlashCommand(name: "status", summary: "Show current session configuration and token usage"),
        SlashCommand(name: "daemon", summary: "Manage the local background server"),
        SlashCommand(name: "warnings", summary: "View retained warnings and diagnostic details"),
        SlashCommand(name: "cd", summary: "Change the current working directory"),
        SlashCommand(name: "pwd", summary: "Show the current working directory"),
        SlashCommand(name: "usage", summary: "View account usage or use a usage limit reset"),
        SlashCommand(name: "debug-config", summary: "Show config layers and requirement sources for debugging"),
        SlashCommand(name: "title", summary: "Configure which items appear in the terminal title"),
        SlashCommand(name: "statusline", summary: "Configure which items appear in the status line"),
        SlashCommand(name: "theme", summary: "Choose a syntax highlighting theme"),
        SlashCommand(name: "pets", summary: "Choose or hide the terminal pet"),
        SlashCommand(name: "mcp", summary: "List MCP tools"),
        SlashCommand(name: "apps", summary: "Manage apps"),
        SlashCommand(name: "plugins", summary: "Browse plugins"),
        SlashCommand(name: "subagents", summary: "Switch between this session’s subagents"),
        SlashCommand(name: "ps", summary: "List background terminals"),
        SlashCommand(name: "stop", summary: "Stop all background terminals"),
        SlashCommand(name: "clear", summary: "Clear the terminal and start a new chat"),
        SlashCommand(name: "feedback", summary: "Send logs to maintainers or save a ZIP"),
        SlashCommand(name: "logout", summary: "Log out of Codex"),
        SlashCommand(name: "quit", summary: "Exit Codex"),
        SlashCommand(name: "exit", summary: "Exit Codex"),
    ]
}
