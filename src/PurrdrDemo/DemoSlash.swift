import Foundation
import PurrdrCore

/// Demo 主機上 Claude Code 的 slash 清單發現(#15)。對 `ClaudeSlashCommand` 的**精確**指令回應，走正式的解析路徑。
///
/// 內容是自己寫的範例：一個 plugin `demo-kit` 以 `plugin.json` 宣告兩個巢狀 skill(`skills/<分類>/<名稱>`),
/// 另一個已安裝但停用的 `old-kit`(不會出現在選單),使用者層一個 skill 與一個指令。
enum DemoSlash {
    static let configDirectory = "/Users/demo/.claude"
    static let installPath = "\(configDirectory)/plugins/cache/demo-market/demo-kit/1.0.0"
    static let oldInstallPath = "\(configDirectory)/plugins/cache/demo-market/old-kit/0.1.0"

    static let installed = #"""
    {"version":2,"plugins":{"demo-kit@demo-market":[{"scope":"user","installPath":"\#(installPath)","version":"1.0.0"}],\#
    "old-kit@demo-market":[{"scope":"user","installPath":"\#(oldInstallPath)","version":"0.1.0"}]}}
    """#
    static let settings = #"{"enabledPlugins":{"demo-kit@demo-market":true,"old-kit@demo-market":false}}"#
    static let manifest = #"{"name":"demo-kit","skills":["./skills/writing/changelog","./skills/review/check-diff"]}"#

    static func respond(to command: String) -> Data? {
        let first = record("F", "installed", "\(configDirectory)/plugins/installed_plugins.json", lines: [installed])
            + record("F", "settings", "\(configDirectory)/settings.json", lines: [settings])
            + record("S", "user", "\(configDirectory)/skills", "\(configDirectory)/skills/weekly-summary/SKILL.md", lines: [
                "name: weekly-summary", "description: Summarize this week's commits",
            ])
            + record("S", "user", "\(configDirectory)/commands", "\(configDirectory)/commands/standup.md", lines: [
                "description: Summarize yesterday's work for standup",
            ])
        for session in DemoTranscripts.sessions {
            for path in [session.path, nil] where command == ClaudeSlashCommand.discover(cwd: session.cwd, transcriptPath: path) {
                return Data(first.utf8)
            }
        }
        if command == ClaudeSlashCommand.manifests(installPaths: [installPath]) {
            return Data(record("F", installPath, "\(installPath)/.claude-plugin/plugin.json", lines: [manifest]).utf8)
        }
        let scans: [ClaudeSlashCommand.Scan] = [
            .init(kind: .skills, plugin: "demo-kit", path: "\(installPath)/skills/writing/changelog"),
            .init(kind: .skills, plugin: "demo-kit", path: "\(installPath)/skills/review/check-diff"),
            .init(kind: .commands, plugin: "demo-kit", path: "\(installPath)/commands"),
        ]
        if command == ClaudeSlashCommand.scan(scans) {
            let changelog = "\(installPath)/skills/writing/changelog"
            let check = "\(installPath)/skills/review/check-diff"
            return Data((record("S", "demo-kit", changelog, "\(changelog)/SKILL.md", lines: [
                "name: changelog", "description: Update CHANGELOG.md for the current change", "argument-hint: \"[version]\"",
            ]) + record("S", "demo-kit", check, "\(check)/SKILL.md", lines: [
                "name: check-diff", "description: Review the working tree diff before committing",
            ])).utf8)
        }
        return nil
    }

    private static func record(_ kind: String, _ fields: String..., lines: [String]) -> String {
        "@" + ([kind] + fields).joined(separator: "\t") + "\n" + lines.map { "|" + $0 + "\n" }.joined()
    }
}
