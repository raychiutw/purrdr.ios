import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import Testing

/// Demo 主機也接受主機檔案的讀寫(記憶體裡的假檔案),所以 Claude 用量在 Demo 走的是正式程式路徑。
@Suite("Demo 主機：Claude 用量")
struct DemoHostFilesTests {
    @Test("同意前檢查：使用者是 demo,尚未安裝")
    func inspectReportsDemoUser() async throws {
        let inspection = try await ClaudePlanUsageHost(channel: DemoHost()).inspect()
        #expect(inspection == ClaudeUsageInspection(user: "demo", isInstalled: false))
    }

    @Test("安裝後讀到範例用量;還原後 settings.json 與安裝前完全相同")
    func installShowsSampleUsageAndRestores() async throws {
        let demo = DemoHost()
        let usage = ClaudePlanUsageHost(channel: demo)
        let files = HostFiles(channel: demo)
        let before = try await files.read([ClaudePlanUsageHost.settingsPath, ".purrdr/claude-usage/journal.json"])
        #expect(try await usage.readPlanUsage() == nil)

        try await usage.install()
        let sample = try #require(try await usage.readPlanUsage())
        #expect(sample.fiveHour != nil && sample.week != nil)
        #expect(abs(sample.capturedAt.timeIntervalSinceNow) < 5 * 60)
        #expect((sample.fiveHour?.resetsAt ?? .distantPast) > Date())
        #expect(try await usage.inspect().isInstalled)

        try await usage.restore()

        #expect(try await files.read([ClaudePlanUsageHost.settingsPath, ".purrdr/claude-usage/journal.json"]) == before)
        #expect(try await usage.readPlanUsage() == nil)
    }

    @Test("Antigravity:安裝後讀到範例用量(兩個模型群組),還原後設定與安裝前完全相同(#448)")
    func antigravityInstallShowsSampleUsageAndRestores() async throws {
        let demo = DemoHost()
        let usage = AntigravityPlanUsageHost(channel: demo)
        let files = HostFiles(channel: demo)
        let before = try await files.read([AntigravityPlanUsageHost.settingsPath])
        #expect(try await usage.readPlanUsage() == nil)

        try await usage.install()
        let sample = try #require(try await usage.readPlanUsage())
        #expect(Set(sample.periods.map(\.group)) == [.gemini, .thirdParty])
        #expect(sample.periods.count == 4)
        #expect(sample.periods.allSatisfy { ($0.resetsAt ?? .distantPast) > Date() })
        #expect(sample.activeGroup == .gemini)

        try await usage.restore()

        #expect(try await files.read([AntigravityPlanUsageHost.settingsPath]) == before)
        #expect(try await usage.readPlanUsage() == nil)
    }

    @Test("讀取後被改過：Demo 也拒絕寫入")
    func demoRejectsStaleWrites() async throws {
        let files = HostFiles(channel: DemoHost())
        let read = try await files.read([ClaudePlanUsageHost.settingsPath])
        guard case .file(_, let version)? = read[ClaudePlanUsageHost.settingsPath] else { Issue.record("Demo 沒有 settings.json"); return }
        try await files.apply([.write(ClaudePlanUsageHost.settingsPath, Data("{}".utf8), expecting: .version(version))])

        await #expect(throws: HostFilesError.changedSinceRead(ClaudePlanUsageHost.settingsPath)) {
            try await files.apply([.write(ClaudePlanUsageHost.settingsPath, Data("{}".utf8), expecting: .version(version))])
        }
    }

    @Test("條件式讀取:Demo 也在已知版本沒變時回 unchanged,變了回新內容")
    func demoConditionalRead() async throws {
        let files = HostFiles(channel: DemoHost())
        let path = HostThemeHost.configPath
        guard case .file(_, let version)? = try await files.read([path])[path] else { Issue.record("Demo 沒有 config.toml"); return }

        #expect(try await files.read([path], knownVersions: [path: version]).unchanged == [path])
        let stale = try await files.read([path], knownVersions: [path: HostFileVersion(checksum: "stale")])
        #expect(stale.unchanged.isEmpty)
        guard case .file(let contents, let current)? = stale[path] else { Issue.record("版本對不上卻沒回內容"); return }
        #expect(!contents.isEmpty)
        #expect(current == version)
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

/// Demo 主機也回答 `codex app-server`(#178),所以 Codex 的方案用量在 Demo 走正式程式路徑。
@Suite("Demo 主機：Codex 方案用量")
struct DemoCodexPlanUsageTests {
    @Test("讀到範例的 5 小時與每週用量週期，重置時間在未來")
    func sampleUsage() async throws {
        let usage = try await CodexPlanUsageHost(channel: DemoHost()).readPlanUsage()

        #expect(usage.periods.map(\.kind) == [.fiveHour, .week])
        #expect(usage.periods.allSatisfy { ($0.resetsAt ?? .distantPast) > Date() })
    }
}
