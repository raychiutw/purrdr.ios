import Foundation
import PurrdrCore
import PurrdrDemo
import Testing

/// Demo 主機也接受主機檔案的讀寫(記憶體裡的假檔案),所以 Claude 用量在 Demo 走的是正式程式路徑。
@Suite("Demo 主機：Claude 用量")
struct DemoHostFilesTests {
    @Test("同意前檢查：使用者是 demo,尚未安裝")
    func inspectReportsDemoUser() async throws {
        let inspection = try await ClaudeUsageHost(channel: DemoHost()).inspect()
        #expect(inspection == ClaudeUsageInspection(user: "demo", isInstalled: false))
    }

    @Test("安裝後讀到範例用量;還原後 settings.json 與安裝前完全相同")
    func installShowsSampleUsageAndRestores() async throws {
        let demo = DemoHost()
        let usage = ClaudeUsageHost(channel: demo)
        let files = HostFiles(channel: demo)
        let before = try await files.read([ClaudeUsageHost.settingsPath, ".purrdr/claude-usage/journal.json"])
        #expect(try await usage.readUsage() == nil)

        try await usage.install()
        let sample = try #require(try await usage.readUsage())
        #expect(sample.fiveHour != nil && sample.week != nil)
        #expect(abs(sample.capturedAt.timeIntervalSinceNow) < 5 * 60)
        #expect((sample.fiveHour?.resetsAt ?? .distantPast) > Date())
        #expect(try await usage.inspect().isInstalled)

        try await usage.restore()

        #expect(try await files.read([ClaudeUsageHost.settingsPath, ".purrdr/claude-usage/journal.json"]) == before)
        #expect(try await usage.readUsage() == nil)
    }

    @Test("讀取後被改過：Demo 也拒絕寫入")
    func demoRejectsStaleWrites() async throws {
        let files = HostFiles(channel: DemoHost())
        let read = try await files.read([ClaudeUsageHost.settingsPath])
        guard case .file(_, let version)? = read[ClaudeUsageHost.settingsPath] else { Issue.record("Demo 沒有 settings.json"); return }
        try await files.apply([.write(ClaudeUsageHost.settingsPath, Data("{}".utf8), expecting: .version(version))])

        await #expect(throws: HostFilesError.changedSinceRead(ClaudeUsageHost.settingsPath)) {
            try await files.apply([.write(ClaudeUsageHost.settingsPath, Data("{}".utf8), expecting: .version(version))])
        }
    }
}

/// Codex 啟動器在 Demo 也走正式程式路徑(記憶體裡的家目錄沒有 `~/.local`)。
@Suite("Demo 主機:Codex 啟動器")
struct DemoCodexLauncherTests {
    @Test("安裝建立 ~/.local/bin/codex;還原後 ~/.local 與安裝紀錄都不在")
    func installAndRestore() async throws {
        let demo = DemoHost()
        let launcher = CodexLauncherHost(channel: demo)
        let files = HostFiles(channel: demo)
        let paths: [HostPath] = [".local", ".local/bin", CodexLauncherHost.launcherPath, ".purrdr/codex-launcher/journal.json"]
        let before = try await files.read(paths)
        #expect(before[".local"] == .missing)
        #expect(try await launcher.inspect() == CodexLauncherInspection(user: "demo", isInstalled: false))

        try await launcher.install()
        #expect(try await files.read(paths)[CodexLauncherHost.launcherPath]?.contents != nil)
        #expect(try await launcher.inspect().isInstalled)

        try await launcher.restore()

        #expect(try await files.read(paths) == before)
    }
}
