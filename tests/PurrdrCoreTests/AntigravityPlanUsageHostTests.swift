#if os(macOS)
import Foundation
import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

/// Antigravity 方案用量的主機端(#448、ADR-0002):在 `~/.gemini/antigravity-cli/settings.json` 裝 statusline 包裝,
/// 關閉時還原。statusline 輸入是 agy 1.5.14 的真實錄製(`other-agents/antigravity/live-1.5.14/statusline-*.json`)。
/// 在本機用真的 `/bin/sh` 跑,家目錄是暫存資料夾;絕不碰真正的家目錄或使用者的 agy。
@Suite("Antigravity 用量(主機)")
struct AntigravityPlanUsageHostTests {
    static let settingsPath = ".gemini/antigravity-cli/settings.json"
    /// 使用者原本的設定:有自訂 statusline(疊在預設狀態列下面)與其他設定。
    static let originalSettings = """
        {
          "model": "gemini-4-neon",
          "statusLine": {
            "type": "command",
            "command": "~/.gemini/antigravity-cli/my-status.sh",
            "enabled": true,
            "padding": 2,
            "stack_with_default": true
          },
          "permissions": { "allow": ["run_command(git status)"] }
        }

        """
    static let originalStatusLineScript = "#!/bin/sh\ncat > \"$HOME/seen.json\"\necho custom agy status\n"

    static func input(_ name: String) -> String {
        String(decoding: Fixtures.otherAgentTranscript("antigravity/live-1.5.14/\(name).json"), as: UTF8.self)
    }

    let host: LocalShellHost
    let usage: AntigravityPlanUsageHost

    init() throws {
        host = try LocalShellHost.temporary()
        usage = AntigravityPlanUsageHost(channel: host)
    }

    func write(_ text: String, to path: String, mode: Int = 0o644) throws {
        let url = host.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func settings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: host.url(Self.settingsPath))) as? [String: Any] ?? [:]
    }

    func statusLine() throws -> [String: Any]? { try settings()["statusLine"] as? [String: Any] }

    /// 以 agy 的方式執行設定裡的 statusline 指令(交給 shell),stdin 給 `input`。
    func runStatusLine(input: String) async throws -> String {
        let command = try #require(try statusLine()?["command"] as? String)
        let session = try await host.execute("\(command) <<'PURRDR_EOF'\n\(input)\nPURRDR_EOF")
        var stdout = Data()
        for try await event in session.output {
            if case .stdout(let data) = event { stdout.append(data) }
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    func setUpAgyHome(settings: String? = originalSettings) throws {
        if let settings {
            try write(settings, to: Self.settingsPath, mode: 0o640)
        } else {
            try FileManager.default.createDirectory(at: host.url(".gemini/antigravity-cli"), withIntermediateDirectories: true)
        }
        try write(Self.originalStatusLineScript, to: ".gemini/antigravity-cli/my-status.sh", mode: 0o755)
    }

    @Test("安裝後還原:整個家目錄與安裝前完全相同(settings.json 的內容與權限、沒有留下 .purrdr)")
    func restoreLeavesHomeExactlyAsBefore() async throws {
        try setUpAgyHome()
        let before = try DirectorySnapshot(of: host.home)

        try await usage.install()
        #expect(try DirectorySnapshot(of: host.home) != before, "安裝沒有改任何東西")
        _ = try await runStatusLine(input: Self.input("statusline-default-idle"))
        try await usage.restore()

        let after = try DirectorySnapshot(of: host.home).entries.filter { $0.key != "seen.json" }
        #expect(after == before.entries)
    }

    @Test("安裝:statusline 換成包裝腳本,其他設定與 statusline 的其他欄位保留")
    func installWrapsStatusLine() async throws {
        try setUpAgyHome()

        try await usage.install()

        let line = try statusLine()
        #expect(line?["command"] as? String == AntigravityPlanUsageHost.wrapperCommand)
        #expect(line?["type"] as? String == "command")
        #expect(line?["enabled"] as? Bool == true)
        #expect(line?["padding"] as? Int == 2)
        #expect(line?["stack_with_default"] as? Bool == true)
        #expect(try settings()["model"] as? String == "gemini-4-neon")
        #expect(try await usage.inspect().isInstalled)
    }

    @Test("原本沒有 statusline:裝成 stack_with_default,預設狀態列照常,包裝腳本不輸出任何字;還原後完全相同")
    func noOriginalStatusLineKeepsDefaultBar() async throws {
        try setUpAgyHome(settings: "{\n  \"model\": \"gemini-4-neon\"\n}\n")
        let before = try DirectorySnapshot(of: host.home)

        try await usage.install()
        #expect(try statusLine()?["stack_with_default"] as? Bool == true)
        #expect(try statusLine()?["enabled"] as? Bool == true)
        #expect(try await runStatusLine(input: Self.input("statusline-default-idle")) == "")
        try await usage.restore()

        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("原本的自訂 statusline 取代預設狀態列(stack_with_default 為 false):裝了之後仍取代,不多出預設狀態列")
    func replacingOriginalKeepsStackSetting() async throws {
        let replacing = Self.originalSettings.replacingOccurrences(of: "\"stack_with_default\": true", with: "\"stack_with_default\": false")
        try setUpAgyHome(settings: replacing)

        try await usage.install()

        #expect(try statusLine()?["stack_with_default"] as? Bool == false)
        #expect(try await runStatusLine(input: Self.input("statusline-default-idle")) == "custom agy status\n")
    }

    @Test("包裝腳本:存下用量與該 session 的狀態,再把同一份輸入交給原本的 statusline,輸出原樣傳回")
    func wrapperSavesUsageAndRunsOriginal() async throws {
        try setUpAgyHome()
        try await usage.install()
        let input = Self.input("statusline-auto-idle")

        let output = try await runStatusLine(input: input)

        #expect(output == "custom agy status\n")
        #expect(try String(contentsOf: host.url("seen.json"), encoding: .utf8) == input.trimmingCharacters(in: .newlines) + "\n")
        let read = try #require(try await usage.readPlanUsage())
        #expect(abs(read.capturedAt.timeIntervalSinceNow) < 60)
        #expect(read.periods.count == 4)
    }

    @Test("quota 換成用量:Gemini 與第三方各自的 5 小時與每週,已用 = 1 - 剩餘;未記載的 bucket 略過")
    func quotaBecomesGroupedPeriods() async throws {
        try setUpAgyHome()
        try await usage.install()
        _ = try await runStatusLine(input: Self.input("statusline-default-idle"))

        let read = try #require(try await usage.readPlanUsage())

        let gemini = read.periods.filter { $0.group == .gemini }
        #expect(gemini.map(\.kind) == [.fiveHour, .week])
        #expect(abs(gemini[0].usedPercentage - 9.21499) < 0.001)
        #expect(abs(gemini[1].usedPercentage - 2.76558) < 0.001)
        #expect(gemini[0].resetsAt == ISO8601DateFormatter().date(from: "2026-11-22T18:30:05Z"))
        let third = read.periods.filter { $0.group == .thirdParty }
        #expect(third.map(\.kind) == [.fiveHour, .week])
        #expect(abs(third[0].usedPercentage - 0) < 0.001)
        #expect(abs(third[1].usedPercentage - 3.338) < 0.001)
        #expect(read.activeGroup == .gemini, "目前模型是 Gemini 4 Neon")
    }

    @Test("目前模型不是 Gemini:活躍群組是第三方")
    func activeGroupFollowsModel() async throws {
        try setUpAgyHome()
        try await usage.install()
        let input = Self.input("statusline-default-idle").replacingOccurrences(of: "Gemini 4 Neon (Medium)", with: "Claude Sonnet 5 (Medium)")
        _ = try await runStatusLine(input: input)

        #expect(try await usage.readPlanUsage()?.activeGroup == .thirdParty)
    }

    @Test("disabled 的 bucket 不顯示;缺少剩餘比例的也略過")
    func disabledBucketsAreHidden() async throws {
        try setUpAgyHome()
        try await usage.install()
        let input = #"{"session_id":"s1","model":{"id":"Gemini 4 Neon (Medium)"},"quota":{"gemini-5h":{"remaining_fraction":0.5,"reset_time":"2026-11-22T18:30:05Z"},"gemini-weekly":{"disabled":true,"remaining_fraction":0.9,"reset_time":"2026-11-29T05:20:28Z"},"3p-5h":{"reset_time":"2026-11-22T18:30:05Z"}}}"#
        _ = try await runStatusLine(input: input)

        let read = try #require(try await usage.readPlanUsage())
        #expect(read.periods.map(\.kind) == [.fiveHour])
        #expect(read.periods.map(\.group) == [.gemini])
    }

    @Test("輸入沒有 quota(例如剛啟動)時不覆寫上次的用量")
    func keepsLastUsageWhenInputHasNoQuota() async throws {
        try setUpAgyHome()
        try await usage.install()
        _ = try await runStatusLine(input: Self.input("statusline-default-idle"))

        _ = try await runStatusLine(input: #"{"session_id":"s2","model":{"id":"Gemini 4 Neon (Medium)"}}"#)

        #expect(try await usage.readPlanUsage()?.periods.count == 4)
    }

    @Test("沒裝過時讀不到用量")
    func noUsageBeforeInstall() async throws {
        try setUpAgyHome()
        #expect(try await usage.readPlanUsage() == nil)
    }

    @Test("各 session 的 context、模型、effort 與權限模式:cycle_mode 有就用,default 模式沒有")
    func sessionStatuses() async throws {
        try setUpAgyHome()
        try await usage.install()
        let sessionID = "00000000-0000-4000-8000-000000000000"
        _ = try await runStatusLine(input: Self.input("statusline-plan-idle"))

        let plan = try #require(try await usage.sessionStatuses(sessionIDs: [sessionID])[sessionID])
        #expect(plan.model == "Gemini 4 Neon (Medium)")
        #expect(plan.effort == "medium")
        #expect(plan.cycleMode == "plan")
        #expect(plan.contextPercent == 0)

        _ = try await runStatusLine(input: Self.input("statusline-default-idle"))
        let normal = try #require(try await usage.sessionStatuses(sessionIDs: [sessionID])[sessionID])
        #expect(normal.cycleMode == nil)
        #expect(try await usage.sessionStatuses(sessionIDs: ["../etc/passwd"]).isEmpty)
    }

    @Test("settings.json 不是合法 JSON(或不是物件):拒絕安裝,主機不變")
    func refusesInvalidSettings() async throws {
        for text in ["{ \"model\": 1, }", "[1, 2]", ""] {
            try write(text, to: Self.settingsPath)
            let before = try DirectorySnapshot(of: host.home)

            await #expect(throws: AntigravityUsageError.settingsNotJSON) { try await usage.inspect() }
            await #expect(throws: AntigravityUsageError.settingsNotJSON) { try await usage.install() }

            #expect(try DirectorySnapshot(of: host.home) == before)
        }
    }

    @Test("主機沒有 ~/.gemini/antigravity-cli:說明沒有 Antigravity,不建立資料夾")
    func refusesWithoutAntigravityDirectory() async throws {
        await #expect(throws: AntigravityUsageError.antigravityNotFound) { try await usage.inspect() }
        await #expect(throws: AntigravityUsageError.antigravityNotFound) { try await usage.install() }
        #expect(try DirectorySnapshot(of: host.home).entries.isEmpty)
    }

    @Test("重複安裝:包裝腳本永遠不會被存成「原本的」statusline,還原後仍與第一次安裝前相同")
    func reinstallNeverSavesWrapperAsOriginal() async throws {
        try setUpAgyHome()
        let before = try DirectorySnapshot(of: host.home)

        try await usage.install()
        try await usage.install()
        #expect(try await runStatusLine(input: Self.input("statusline-default-idle")) == "custom agy status\n")
        try await usage.restore()

        #expect(try DirectorySnapshot(of: host.home).entries.filter { $0.key != "seen.json" } == before.entries)
    }

    @Test("使用者在安裝後自己換掉 statusline:還原時不動它")
    func restoreLeavesUserChangedStatusLine() async throws {
        try setUpAgyHome()
        try await usage.install()
        try write(#"{"statusLine":{"type":"command","command":"/usr/bin/true"}}"#, to: Self.settingsPath)

        try await usage.restore()

        #expect(try statusLine()?["command"] as? String == "/usr/bin/true")
    }
}
#endif
