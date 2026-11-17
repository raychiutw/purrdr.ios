import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Claude Code 的 slash 清單在主機上發現(#15、行為規格 F9.1–F9.2)。以 `LocalShellHost` 對作者 Mac 錄下的
/// plugin 結構(`ClaudePluginsFixture`)跑同一份主機腳本。
@Suite("Slash 清單：Claude Code 主機發現")
struct ClaudeSlashDiscoveryTests {
    static func host() throws -> LocalShellHost {
        let host = try LocalShellHost.temporary()
        try ClaudePluginsFixture.install(into: host)
        return host
    }

    static func names(in catalog: SlashCatalog, source: SlashSource) -> [String] {
        catalog.sections.first { $0.source == source }?.commands.map(\.name) ?? []
    }

    /// herdrchat 只看預設的 `skills/<名稱>/SKILL.md`,`mattpocock-skills` 以 `plugin.json` 宣告的
    /// `skills/<分類>/<名稱>` 全部漏掉。宣告了路徑就只用宣告的路徑：沒宣告的 in-progress／misc 不出現。
    @Test("依 plugin.json 宣告的路徑找 skill:mattpocock-skills 宣告的 27 個巢狀 skill 都出現，沒宣告的不出現")
    func declaredNestedSkillsAppear() async throws {
        let host = try Self.host()
        let catalog = await ClaudeSlashDiscovery(channel: host).catalog(cwd: nil, transcriptPath: nil)

        let matt = Self.names(in: catalog, source: .plugin("mattpocock-skills"))
        #expect(Set(matt) == Set(ClaudePluginsFixture.mattpocockDeclared.map { "mattpocock-skills:\($0)" }))
        #expect(matt.count == 27)
        for undeclared in ClaudePluginsFixture.mattpocockUndeclared {
            #expect(!matt.contains("mattpocock-skills:\(undeclared)"))
        }
        #expect(catalog.isComplete)
    }

    /// 作者 Mac 上所有 plugin 都是啟用的;錄製檔改動：把 `frontend-design` 設成 `false`(使用者層)、
    /// `webwright` 在專案層 `.claude/settings.local.json` 設成 `false`。
    @Test("settings.json 的 enabledPlugins 為 false 的 plugin 不出現(專案層設定蓋過使用者層)")
    func disabledPluginsAreExcluded() async throws {
        let host = try Self.host()
        let all = await ClaudeSlashDiscovery(channel: host).catalog(cwd: nil, transcriptPath: nil)
        #expect(Self.names(in: all, source: .plugin("frontend-design")) == ["frontend-design:frontend-design"])
        #expect(Self.names(in: all, source: .plugin("webwright")).contains("webwright:webwright"))

        let settings = try String(contentsOf: host.home.appending(path: ".claude/settings.json"), encoding: .utf8)
            .replacingOccurrences(of: #""frontend-design@claude-plugins-official": true"#, with: #""frontend-design@claude-plugins-official": false"#)
        try host.write(Data(settings.utf8), to: ".claude/settings.json")
        let project = host.home.appending(path: "Projects/ledger").path(percentEncoded: false)
        try host.write(Data(#"{"enabledPlugins":{"webwright@webwright":false}}"#.utf8), to: "Projects/ledger/.claude/settings.local.json")

        let catalog = await ClaudeSlashDiscovery(channel: host).catalog(cwd: project, transcriptPath: nil)
        #expect(Self.names(in: catalog, source: .plugin("frontend-design")).isEmpty)
        #expect(Self.names(in: catalog, source: .plugin("webwright")).isEmpty)
        #expect(!catalog.sections.flatMap(\.commands).contains { $0.name.hasPrefix("frontend-design:") || $0.name.hasPrefix("webwright:") })
        #expect(Self.names(in: catalog, source: .plugin("mattpocock-skills")).count == 27)
    }

    @Test("plugin 指令:plugin.json 宣告的 commands 路徑(陣列、指向 skill 內的資料夾)與預設 commands/")
    func pluginCommands() async throws {
        let host = try Self.host()
        let catalog = await ClaudeSlashDiscovery(channel: host).catalog(cwd: nil, transcriptPath: nil)
        let agentSkills = Self.names(in: catalog, source: .plugin("agent-skills"))
        // `"commands": ["./.claude/commands", "./commands"]`:前者是 .md,後者只有 .toml(不是 Claude 的指令)。
        for command in ["build", "code-simplify", "constraints", "plan", "review", "ship", "spec", "test", "webperf"] {
            #expect(agentSkills.contains("agent-skills:\(command)"))
        }
        #expect(agentSkills.contains("agent-skills:test-driven-development"))
        // 使用者層的 plugin(0.6.16)才算，專案層那筆(other-project-1)不適用於「沒有 cwd」。
        #expect(Self.names(in: catalog, source: .plugin("webwright")).sorted() == ["webwright:craft", "webwright:run", "webwright:webwright"])
        #expect(Self.names(in: catalog, source: .plugin("superpowers")).count == 15)
        #expect(Self.names(in: catalog, source: .plugin("skill-creator")) == ["skill-creator:skill-creator"])
    }

    @Test("說明與參數提示取自 frontmatter(含 block scalar)")
    func summariesComeFromFrontmatter() async throws {
        let host = try Self.host()
        let catalog = await ClaudeSlashDiscovery(channel: host).catalog(cwd: nil, transcriptPath: nil)
        let commands = catalog.sections.flatMap(\.commands)
        let handoff = commands.first { $0.name == "mattpocock-skills:handoff" }
        #expect(handoff?.argumentHint == "What will the next session be used for?")
        #expect(handoff?.summary.isEmpty == false)
        #expect(commands.first { $0.name == "mattpocock-skills:tdd" }?.summary.hasPrefix("Test-driven development.") == true)
    }

    @Test("使用者層 skills;專案層 skills 與 commands(巢狀指令以 : 命名空間);專案層安裝的 plugin 只在該資料夾出現")
    func userAndProjectEntries() async throws {
        let host = try Self.host()
        try host.write(Data("---\nname: release\ndescription: >-\n  Cut a release\n  for the ledger app\nargument-hint: <version>\n---\nbody\n".utf8), to: "Projects/ledger/.claude/skills/release/SKILL.md")
        try host.write(Data("---\ndescription: Run the migrations\n---\n".utf8), to: "Projects/ledger/.claude/commands/db/migrate.md")
        let project = host.home.appending(path: "Projects/ledger").path(percentEncoded: false)
        let catalog = await ClaudeSlashDiscovery(channel: host).catalog(cwd: project, transcriptPath: nil)

        let projectSection = catalog.sections.first { $0.source == .project }?.commands ?? []
        #expect(projectSection == [
            SlashCommand(name: "db:migrate", summary: "Run the migrations"),
            SlashCommand(name: "release", argumentHint: "<version>", summary: "Cut a release for the ledger app"),
        ])
        let user = Self.names(in: catalog, source: .user)
        #expect(user.contains("cloudflare"))
        #expect(user.contains("wrangler"))
        #expect(user.count == 20)
        #expect(catalog.sections.first?.source == .builtIn)
        #expect(Self.names(in: catalog, source: .builtIn).contains("compact"))

        let other = host.home.appending(path: "Projects/other-project-1").path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        // 專案層那筆 agent-skills 是 0.6.15:兩版的內容一樣，只能從「有沒有出錯」看出選了哪筆;這裡只確認仍出現。
        let otherCatalog = await ClaudeSlashDiscovery(channel: host).catalog(cwd: other, transcriptPath: nil)
        #expect(Self.names(in: otherCatalog, source: .plugin("agent-skills")).contains("agent-skills:build"))
    }

    /// `skill_listing` 只列模型可呼叫的 skill(`/implement` 這類 `disable-model-invocation` 的不在裡面),
    /// 所以和主機掃描合併：兩邊都要出現，Claude Code 自帶的 skill(主機上找不到出處)歸到「其他」。
    @Test("對話紀錄的 skill_listing 與主機掃描合併")
    func skillListingMergesWithScan() async throws {
        let host = try Self.host()
        let listing = String(decoding: Fixtures.transcript("skill-listing.jsonl"), as: UTF8.self)
        // 錄製檔改動：之後的增量(`isInitial: false`)多了一個 skill。
        let delta = Fixtures.transcriptLine(0, of: "skill-listing.jsonl") { row in
            var attachment = row["attachment"] as? [String: Any] ?? [:]
            attachment["isInitial"] = false
            attachment["names"] = ["late-skill"]
            attachment["content"] = "- late-skill: Added after the session started"
            attachment["skillCount"] = 1
            row["attachment"] = attachment
        }
        try host.write(Data((listing + delta + "\n").utf8), to: ".claude/projects/-Users-demo-Projects-ledger/s.jsonl")
        let path = host.home.appending(path: ".claude/projects/-Users-demo-Projects-ledger/s.jsonl").path(percentEncoded: false)
        let catalog = await ClaudeSlashDiscovery(channel: host).catalog(cwd: nil, transcriptPath: path)

        let matt = Self.names(in: catalog, source: .plugin("mattpocock-skills"))
        #expect(matt.count == 27)
        #expect(matt.contains("mattpocock-skills:implement"))
        let session = Self.names(in: catalog, source: .session)
        #expect(session.contains("late-skill"))
        #expect(session.contains("dataviz"))
        #expect(!session.contains("cloudflare"))  // 使用者層找得到出處
        #expect(!session.contains("init"))  // 內建
        #expect(Self.names(in: catalog, source: .plugin("anthropic-skills")).contains("anthropic-skills:pdf"))
        let all = catalog.sections.flatMap(\.commands)
        #expect(Set(all.map(\.name)).count == all.count)
        #expect(all.first { $0.name == "dataviz" }?.summary.isEmpty == false)
    }

    @Test("時間上限到了還沒做完：回傳已讀到的部分，標示清單不完整")
    func timeLimitMarksIncomplete() async throws {
        let host = FakeHost()
        await host.expect(ClaudeSlashCommand.discover(cwd: nil, transcriptPath: nil), reply: FakeReply(keepsOpen: true))
        let sleeper = RecordingSleeper { _ in true }
        let catalog = await ClaudeSlashDiscovery(channel: host, timeLimit: .seconds(20), sleep: sleeper.sleep).catalog(cwd: nil, transcriptPath: nil)
        #expect(!catalog.isComplete)
        #expect(Self.names(in: catalog, source: .builtIn).contains("compact"))
        #expect(Set(await sleeper.requested) == [.seconds(20)])
    }
}
