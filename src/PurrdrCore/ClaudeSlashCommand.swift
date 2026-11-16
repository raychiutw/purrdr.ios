/// 主機指令建構：發現 Claude Code slash 清單的 POSIX 腳本(#15)。Windows 主機由 `WindowsHostChannel` 換成
/// 同樣輸出格式的 PowerShell 版本(`WindowsScripts.slashDiscover` 等，#68)。
///
/// 腳本不解析 JSON(主機上不一定有 python／jq):只把檔案原樣印出來，由 app 解析後決定下一步要讀哪些路徑。
/// 一共三步，每步一個指令:
///
/// 1. `discover`:`installed_plugins.json`、各層 `settings.json`、使用者與專案層的 skills／commands、
///    對話紀錄中的 `skill_listing` 行。
/// 2. `manifests`:每個要用的 plugin 的 `.claude-plugin/plugin.json`。
/// 3. `scan`:依 `plugin.json` 宣告(沒宣告才用預設)的 skills／commands 路徑。
///
/// **不設深度與檔案數上限**(herdrchat 的上限讓巢狀宣告的 skill 漏掉),只由 `ClaudeSlashDiscovery` 設時間上限。
///
/// 輸出格式：每筆紀錄一行標頭(以 `@` 開頭、欄位以 TAB 分隔),之後內容每行前面加 `|`,所以檔案內容不會被當成標頭。
/// - `@F TAB 標籤 TAB 路徑`:整個檔案。
/// - `@S TAB 標籤 TAB 基準資料夾 TAB 路徑`:一個 SKILL.md 或指令 .md 的 frontmatter(不含 `---`)。
/// - `@L`:對話紀錄中含 `"skill_listing"` 的行。
public enum ClaudeSlashCommand {
    /// 共用的 shell 函式。
    static let functions = #"""
    T=$(printf '\t')
    dump() { if [ -f "$2" ]; then printf '@F%s%s%s%s\n' "$T" "$1" "$T" "$2"; sed 's/^/|/' "$2"; printf '\n'; fi; }
    fm() { printf '@S%s%s%s%s%s%s\n' "$T" "$1" "$T" "$2" "$T" "$3"; awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print "|" $0 }' "$3"; }
    skills() { if [ -f "$2/SKILL.md" ]; then fm "$1" "$2" "$2/SKILL.md"; elif [ -d "$2" ]; then for s in "$2"/*/SKILL.md; do if [ -f "$s" ]; then fm "$1" "$2" "$s"; fi; done; fi; }
    commands() { if [ -f "$2" ]; then fm "$1" "${2%/*}" "$2"; elif [ -d "$2" ]; then find -L "$2" -type f -name '*.md' -print 2>/dev/null | while IFS= read -r m; do fm "$1" "$2" "$m"; done; fi; }
    """#

    /// 第 1 步。參數：工作資料夾(沒有時空字串)、對話紀錄路徑(沒有時空字串)。
    public static func discover(cwd: String?, transcriptPath: String?) -> String {
        TranscriptCommand.command(discoverScript, arguments: [cwd ?? "", transcriptPath ?? ""])
    }

    static let discoverScript = functions + "\n" + #"""
        c=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
        dump installed "$c/plugins/installed_plugins.json"
        dump settings "$c/settings.json"
        if [ -n "$1" ]; then
        dump project-settings "$1/.claude/settings.json"
        dump local-settings "$1/.claude/settings.local.json"
        skills project "$1/.claude/skills"
        commands project "$1/.claude/commands"
        fi
        skills user "$c/skills"
        commands user "$c/commands"
        if [ -n "$2" ] && [ -r "$2" ]; then
        printf '@L\n'
        grep -F '"skill_listing"' "$2" | sed 's/^/|/'
        fi
        """#

    /// 第 2 步。參數：每個 plugin 的 installPath。
    public static func manifests(installPaths: [String]) -> String {
        TranscriptCommand.command(manifestsScript, arguments: installPaths)
    }

    static let manifestsScript = functions + "\n" + #"for p in "$@"; do dump "$p" "$p/.claude-plugin/plugin.json"; done"#

    /// 第 3 步要掃的一個路徑。
    public struct Scan: Sendable, Equatable {
        public enum Kind: String, Sendable { case skills = "s", commands = "c" }
        public var kind: Kind
        /// plugin 名稱。
        public var plugin: String
        public var path: String

        public init(kind: Kind, plugin: String, path: String) {
            self.kind = kind
            self.plugin = plugin
            self.path = path
        }
    }

    /// 第 3 步。參數：每個路徑三個(種類、plugin 名稱、路徑)。
    public static func scan(_ scans: [Scan]) -> String {
        TranscriptCommand.command(scanScript, arguments: scans.flatMap { [$0.kind.rawValue, $0.plugin, $0.path] })
    }

    static let scanScript = functions + "\n" + #"""
        while [ $# -ge 3 ]; do
        if [ "$1" = s ]; then skills "$2" "$3"; else commands "$2" "$3"; fi
        shift 3
        done
        """#
}
