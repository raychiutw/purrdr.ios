#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Claude 用量的主機端(行為規格 F18):包裝 `~/.claude/settings.json` 的 status line,關閉時還原。
/// 在本機用真的 `/bin/sh` 跑，家目錄是暫存資料夾。
@Suite("Claude 用量(主機)")
struct ClaudeUsageHostTests {
    static let originalSettings = """
        {
          "model": "opus",
          "statusLine": {
            "type": "command",
            "command": "~/.claude/statusline.sh",
            "padding": 1
          },
          "permissions": { "allow": ["Bash(git status)"] }
        }

        """
    /// 使用者原本的 status line:把輸入存起來，印一行字。
    static let originalStatusLineScript = "#!/bin/sh\ncat > \"$HOME/seen.json\"\necho original status line\n"
    static let statusLineInput = #"{"session_id":"s1","model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}"#

    let host: LocalShellHost
    let usage: ClaudeUsageHost

    init() throws {
        host = try LocalShellHost()
        usage = ClaudeUsageHost(channel: host)
    }

    func write(_ text: String, to path: String, mode: Int = 0o644) throws {
        let url = host.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func settings(_ path: String = ".claude/settings.json") throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: host.url(path))) as? [String: Any] ?? [:]
    }

    /// 以 Claude Code 的方式執行設定裡的 status line 指令，stdin 給 `input`。
    func runStatusLine(input: String) async throws -> String {
        let command = try #require((try settings()["statusLine"] as? [String: Any])?["command"] as? String)
        let session = try await host.execute(command)
        try await session.write(Data(input.utf8))
        await session.closeStdin()
        var stdout = Data()
        for try await event in session.output {
            if case .stdout(let data) = event { stdout.append(data) }
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    func setUpClaudeHome() throws {
        try write(Self.originalSettings, to: ".claude/settings.json", mode: 0o640)
        try write(Self.originalStatusLineScript, to: ".claude/statusline.sh", mode: 0o755)
    }

    @Test("安裝後還原：整個家目錄與安裝前完全相同(settings.json 的內容與權限、沒有留下 .purrdr)")
    func restoreLeavesHomeExactlyAsBefore() async throws {
        try setUpClaudeHome()
        let before = try DirectorySnapshot(of: host.home)

        try await usage.install()
        #expect(try DirectorySnapshot(of: host.home) != before, "安裝沒有改任何東西")
        #expect(try await runStatusLine(input: Self.statusLineInput) == "original status line\n")
        try await usage.restore()

        let snapshot = try DirectorySnapshot(of: host.home)
        let after = snapshot.entries.filter { $0.key != "seen.json" }
        #expect(after == before.entries, "還原後不同:\n\(snapshot)\n---\n\(before)")
    }

    @Test("安裝：status line 換成包裝腳本，其他設定與 status line 的其他欄位保留")
    func installWrapsStatusLine() async throws {
        try setUpClaudeHome()

        try await usage.install()

        let settings = try settings()
        let statusLine = settings["statusLine"] as? [String: Any]
        #expect(statusLine?["command"] as? String == ClaudeUsageHost.wrapperCommand)
        #expect(statusLine?["type"] as? String == "command")
        #expect(statusLine?["padding"] as? Int == 1)
        #expect(settings["model"] as? String == "opus")
        #expect((settings["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(git status)"])
        #expect(try await usage.inspect().isInstalled)
    }

    @Test("包裝腳本：存下用量，再把同一份輸入交給原本的 status line,輸出原樣傳回")
    func wrapperSavesUsageAndRunsOriginal() async throws {
        try setUpClaudeHome()
        try await usage.install()

        let output = try await runStatusLine(input: Self.statusLineInput)

        #expect(output == "original status line\n")
        #expect(try String(contentsOf: host.url("seen.json"), encoding: .utf8) == Self.statusLineInput + "\n")
        let read = try #require(try await usage.readUsage())
        #expect(read.fiveHour == .init(usedPercentage: 23.5, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)))
        #expect(read.week == .init(usedPercentage: 41.2, resetsAt: Date(timeIntervalSince1970: 1_738_857_600)))
        #expect(abs(read.capturedAt.timeIntervalSinceNow) < 60)
    }

    @Test("輸入沒有 rate_limits(session 剛開始)時不覆寫上次的用量")
    func wrapperKeepsLastUsageWhenInputHasNoRateLimits() async throws {
        try setUpClaudeHome()
        try await usage.install()
        _ = try await runStatusLine(input: Self.statusLineInput)

        _ = try await runStatusLine(input: #"{"session_id":"s2"}"#)

        #expect(try await usage.readUsage()?.fiveHour?.usedPercentage == 23.5)
    }

    @Test("沒裝過時讀不到用量")
    func noUsageBeforeInstall() async throws {
        try setUpClaudeHome()
        #expect(try await usage.readUsage() == nil)
    }

    @Test("原本沒有 settings.json:安裝時建立，包裝腳本不輸出任何字;還原時刪除")
    func createsAndDeletesSettings() async throws {
        try FileManager.default.createDirectory(at: host.url(".claude"), withIntermediateDirectories: true)
        let before = try DirectorySnapshot(of: host.home)

        try await usage.install()
        #expect(try await runStatusLine(input: Self.statusLineInput) == "")
        #expect(try await usage.readUsage() != nil)
        try await usage.restore()

        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("settings.json 是 symlink:寫到真正的檔案，symlink 保留;還原後完全相同")
    func followsSymlinkedSettings() async throws {
        try write(Self.originalSettings, to: "dotfiles/claude-settings.json")
        try FileManager.default.createDirectory(at: host.url(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: host.url(".claude/settings.json").path, withDestinationPath: "../dotfiles/claude-settings.json")
        let before = try DirectorySnapshot(of: host.home)

        try await usage.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: host.url(".claude/settings.json").path) == "../dotfiles/claude-settings.json")
        #expect((try settings("dotfiles/claude-settings.json")["statusLine"] as? [String: Any])?["command"] as? String == ClaudeUsageHost.wrapperCommand)
        try await usage.restore()

        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("settings.json 不是合法 JSON(或不是物件):拒絕安裝，主機不變")
    func refusesInvalidSettings() async throws {
        for text in ["{ \"model\": \"opus\", }", "[1, 2]", ""] {
            try write(text, to: ".claude/settings.json")
            let before = try DirectorySnapshot(of: host.home)

            await #expect(throws: ClaudeUsageError.settingsNotJSON) { try await usage.inspect() }
            await #expect(throws: ClaudeUsageError.settingsNotJSON) { try await usage.install() }

            #expect(try DirectorySnapshot(of: host.home) == before)
        }
    }

    @Test("主機沒有 ~/.claude:說明沒有 Claude Code 設定，不建立資料夾")
    func refusesWithoutClaudeDirectory() async throws {
        await #expect(throws: ClaudeUsageError.claudeNotFound) { try await usage.inspect() }
        await #expect(throws: ClaudeUsageError.claudeNotFound) { try await usage.install() }
        #expect(try DirectorySnapshot(of: host.home).entries.isEmpty)
    }

    @Test("檢查時回報會以哪個主機使用者修改")
    func inspectReportsUser() async throws {
        try setUpClaudeHome()
        let inspection = try await usage.inspect()
        #expect(inspection.user == NSUserName())
        #expect(!inspection.isInstalled)
    }

    @Test("重複安裝：包裝腳本永遠不會被存成「原本的」status line,還原後仍與第一次安裝前相同")
    func reinstallNeverSavesWrapperAsOriginal() async throws {
        try setUpClaudeHome()
        let before = try DirectorySnapshot(of: host.home)

        try await usage.install()
        try await usage.install()
        #expect(try await usage.inspect().isInstalled)
        #expect(try await runStatusLine(input: Self.statusLineInput) == "original status line\n")
        try await usage.restore()

        let after = try DirectorySnapshot(of: host.home).entries.filter { $0.key != "seen.json" }
        #expect(after == before.entries)
    }

    @Test("設定已指向包裝腳本卻沒有安裝紀錄：不把包裝腳本當成原本的 status line")
    func wrapperWithoutJournalIsNotOriginal() async throws {
        try write(#"{"statusLine":{"type":"command","command":"\#(ClaudeUsageHost.wrapperCommand)"}}"#, to: ".claude/settings.json")

        try await usage.install()

        // 若把包裝腳本存成原本的，執行時會無限遞迴呼叫自己，直到程序數用盡才失敗(要好幾秒)。
        let started = ContinuousClock.now
        #expect(try await runStatusLine(input: Self.statusLineInput) == "")
        #expect(ContinuousClock.now - started < .seconds(3), "status line 執行太久，可能在遞迴呼叫自己")
    }

    @Test("安裝後使用者又改了 settings.json:還原只換回 status line,保留使用者的修改")
    func restoreKeepsUserEditsMadeAfterInstall() async throws {
        try setUpClaudeHome()
        try await usage.install()
        var edited = try settings()
        edited["theme"] = "dark"
        try JSONSerialization.data(withJSONObject: edited).write(to: host.url(".claude/settings.json"))

        try await usage.restore()

        let restored = try settings()
        #expect(restored["theme"] as? String == "dark")
        #expect(restored["model"] as? String == "opus")
        let statusLine = restored["statusLine"] as? [String: Any]
        #expect(statusLine?["command"] as? String == "~/.claude/statusline.sh")
        #expect(statusLine?["padding"] as? Int == 1)
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr").path))
    }

    @Test("安裝後使用者自己把 status line 換掉了：還原不動它")
    func restoreLeavesUserReplacedStatusLine() async throws {
        try setUpClaudeHome()
        try await usage.install()
        try write(#"{"statusLine":{"type":"command","command":"my-new-line"}}"#, to: ".claude/settings.json")

        try await usage.restore()

        #expect((try settings()["statusLine"] as? [String: Any])?["command"] as? String == "my-new-line")
    }
}
#endif
