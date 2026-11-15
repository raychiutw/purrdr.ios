import Foundation

#if os(macOS)

/// 作者 Mac 上真實的 Claude Code plugin／skill／指令結構(`Fixtures/claude-plugins/home`,
/// `scripts/record-claude-plugins-fixture.py` 錄製、去識別化;說明見 `Fixtures/README.md`)。
public enum ClaudePluginsFixture {
    /// 錄製時的假家目錄;安裝到 `LocalShellHost` 時換成它的暫存家目錄。
    public static let recordedHome = "/Users/demo"

    /// 把整棵樹複製到 `host` 的家目錄下，檔案內的 `/Users/demo` 換成實際的家目錄(installPath 是絕對路徑)。
    public static func install(into host: LocalShellHost) throws {
        guard let root = Bundle.module.url(forResource: "home", withExtension: nil, subdirectory: "Fixtures/claude-plugins") else {
            fatalError("找不到 Fixtures/claude-plugins/home")
        }
        let home = host.home.path(percentEncoded: false)
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: recordedHome, with: trimmedHome)
            try host.write(Data(text.utf8), to: relative)
        }
    }

    /// 錄製時 `mattpocock-skills` 的 `plugin.json` 宣告的 27 個 skill(`skills/<分類>/<名稱>`)。
    public static let mattpocockDeclared = [
        "ask-matt", "diagnosing-bugs", "grill-with-docs", "triage", "improve-codebase-architecture", "setup-matt-pocock-skills",
        "tdd", "to-spec", "to-tickets", "wayfinder", "implement", "implement-spec", "prototype", "research", "domain-modeling",
        "codebase-design", "code-review", "pr", "retro", "wizard", "grill-me", "grilling", "handoff", "teach", "to-questionnaire",
        "wait-what", "writing-for-agents",
    ]

    /// 同一個 plugin 裡有 SKILL.md、但 `plugin.json` **沒有宣告**的 11 個(`skills/in-progress`、`skills/misc`):
    /// Claude Code 不載入它們(作者 Mac 上所有 session 的 `skill_listing` 與對話紀錄都沒出現過)。
    public static let mattpocockUndeclared = [
        "chief-of-staff", "claude-handoff", "loop-me", "setup-ts-deep-modules", "writing-beats", "writing-fragments", "writing-shape",
        "git-guardrails-claude-code", "migrate-to-shoehorn", "scaffold-exercises", "setup-pre-commit",
    ]
}

#endif
