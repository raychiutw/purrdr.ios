#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

@testable import PurrdrSSH

/// 每個 session 一份 status line 檔(#388):包裝腳本以真的 `/bin/sh` 跑,app 端讀取與對應 session。
@Suite("Claude session 狀態(每個 session 一份檔)")
struct ClaudeSessionStatusTests {
    static func input(session: String, percent: Double?, size: Int = 1_000_000, model: String = "claude-opus-5-5", effort: String? = "high", rateLimits: Bool = false) -> String {
        let used = percent.map { "\($0)" } ?? "null"
        let effort = effort.map { #","effort":{"level":"\#($0)"}"# } ?? ""
        let limits = rateLimits ? #","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1738425600}}"# : ""
        return #"{"session_id":"\#(session)","model":{"id":"\#(model)"},"context_window":{"context_window_size":\#(size),"used_percentage":\#(used)}\#(effort)\#(limits)}"#
    }

    let host: LocalShellHost
    let usage: ClaudePlanUsageHost

    init() throws {
        host = try LocalShellHost.temporary()
        usage = ClaudePlanUsageHost(channel: host)
        try FileManager.default.createDirectory(at: host.url(".claude"), withIntermediateDirectories: true)
    }

    func runStatusLine(_ input: String) async throws {
        let command = ClaudePlanUsageHost.wrapperCommand
        let session = try await host.execute("printf '%s\\n' \(PosixShell.quote(input)) | \(command)")
        for try await _ in session.output {}
    }

    @Test("多個 Agent 同時跑:各自的 context 不互相覆蓋")
    func sessionsDoNotOverwriteEachOther() async throws {
        try await usage.install()
        try await runStatusLine(Self.input(session: "sess-a", percent: 12.5))
        try await runStatusLine(Self.input(session: "sess-b", percent: 80, size: 200_000, model: "claude-sonnet-5-5", effort: "low"))
        try await runStatusLine(Self.input(session: "sess-a", percent: 15))

        let statuses = try await usage.sessionStatuses(sessionIDs: ["sess-a", "sess-b", "sess-missing"])

        #expect(statuses.keys.sorted() == ["sess-a", "sess-b"])
        #expect(statuses["sess-a"]?.contextPercent == 15)
        #expect(statuses["sess-a"]?.contextWindowSize == 1_000_000)
        #expect(statuses["sess-a"]?.model == "claude-opus-5-5")
        #expect(statuses["sess-a"]?.effort == "high")
        #expect(statuses["sess-b"]?.contextPercent == 80)
        #expect(statuses["sess-b"]?.contextWindowSize == 200_000)
        #expect(statuses["sess-b"]?.effort == "low")
    }

    @Test("沒有 rate_limits 也寫 session 檔,usage.json 不被覆寫;有 rate_limits 才寫 usage.json")
    func sessionFileWithoutRateLimits() async throws {
        try await usage.install()
        try await runStatusLine(Self.input(session: "s1", percent: 5))

        #expect(FileManager.default.fileExists(atPath: host.url(".purrdr/claude-usage/sessions/s1.json").path))
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr/claude-usage/usage.json").path))

        try await runStatusLine(Self.input(session: "s1", percent: 6, rateLimits: true))
        #expect(try await usage.readPlanUsage()?.fiveHour?.usedPercentage == 10)
        try await runStatusLine(Self.input(session: "s1", percent: 7))
        #expect(try await usage.readPlanUsage()?.fiveHour?.usedPercentage == 10)
    }

    @Test("超過 7 天沒更新的 session 檔被清掉,較新的保留")
    func oldSessionFilesAreRemoved() async throws {
        try await usage.install()
        try await runStatusLine(Self.input(session: "old", percent: 1))
        try await runStatusLine(Self.input(session: "recent", percent: 2))
        let old = host.url(".purrdr/claude-usage/sessions/old.json")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: old.path)

        try await runStatusLine(Self.input(session: "now", percent: 3))

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: host.url(".purrdr/claude-usage/sessions/recent.json").path))
        #expect(FileManager.default.fileExists(atPath: host.url(".purrdr/claude-usage/sessions/now.json").path))
    }

    @Test("不合規則的 session id 不寫檔(也不會跳出資料夾)")
    func invalidSessionIDIsNotWritten() async throws {
        try await usage.install()
        try await runStatusLine(Self.input(session: "..", percent: 1))
        try await runStatusLine(Self.input(session: "a/b", percent: 1))

        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: host.url(".purrdr/claude-usage/sessions").path)) ?? []
        #expect(sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr/claude-usage/...json").path))
    }

    @Test("讀取:app 以同一規則組檔名,不合格的 id 不讀;沒裝時是空的")
    func readerRejectsInvalidIDs() async throws {
        #expect(try await usage.sessionStatuses(sessionIDs: ["s1"]).isEmpty)
        try await usage.install()
        try await runStatusLine(Self.input(session: "s1", percent: 5))

        let statuses = try await usage.sessionStatuses(sessionIDs: ["../usage", "s1", ""])

        #expect(statuses.keys.sorted() == ["s1"])
    }

    @Test("session 檔過期(超過 7 天)不採用")
    func expiredStatusIsIgnored() async throws {
        try await usage.install()
        try await runStatusLine(Self.input(session: "s1", percent: 5))

        let later = Date().addingTimeInterval(8 * 86400)

        #expect(try await usage.sessionStatuses(sessionIDs: ["s1"], now: later).isEmpty)
    }

    @Test("已裝舊版包裝:偵測出來;重新安裝(經同意流程)後換成新的")
    func detectsOutdatedWrapper() async throws {
        try await usage.install()
        #expect(try await usage.isWrapperOutdated() == false)

        let wrapper = host.url(".purrdr/claude-usage/statusline.sh")
        try Data("#!/bin/sh\n# old wrapper\n".utf8).write(to: wrapper)
        #expect(try await usage.isWrapperOutdated() == true)

        try await usage.install()
        #expect(try await usage.isWrapperOutdated() == false)
        #expect(try String(contentsOf: wrapper, encoding: .utf8) == ClaudePlanUsageHost.wrapperScript)
    }

    @Test("沒裝包裝時不算舊版")
    func notInstalledIsNotOutdated() async throws {
        #expect(try await usage.isWrapperOutdated() == false)
    }

    @Test("app 內嵌的腳本與同步來的 vendor 檔案一致,Windows 版轉給原 status line 的 stdin 不帶 BOM")
    func embeddedScriptsMatchVendor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sh = try String(contentsOf: root.appending(path: "vendor/purrdr-host/claude-usage/statusline.sh"), encoding: .utf8)
        let ps1 = try String(contentsOf: root.appending(path: "vendor/purrdr-host/claude-usage/statusline.ps1"), encoding: .utf8)
        #expect(ClaudePlanUsageHost.wrapperScript == sh)
        #expect(ClaudePlanUsageHost.windowsWrapperScript == ps1)
        #expect(ps1.contains("[Console]::InputEncoding = $utf8"))
    }

    @Test("解析 session 檔:缺 used_percentage、或 session id 不合規則時")
    func parsing() throws {
        let nullPercent = Data(#"{"captured_at":1700000000,"session_id":"s1","status_line_input":\#(Self.input(session: "s1", percent: nil))}"#.utf8)
        let status = try #require(ClaudeSessionStatus(sessionFile: nullPercent))
        #expect(status.contextPercent == nil)
        #expect(status.capturedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let clamped = Data(#"{"captured_at":1,"session_id":"s1","status_line_input":\#(Self.input(session: "s1", percent: 140))}"#.utf8)
        #expect(ClaudeSessionStatus(sessionFile: clamped)?.contextPercent == 100)

        let bad = Data(#"{"captured_at":1,"session_id":"a/b","status_line_input":{}}"#.utf8)
        #expect(ClaudeSessionStatus(sessionFile: bad) == nil)
        #expect(ClaudeSessionStatus.isValidSessionID(String(repeating: "a", count: 128)))
        #expect(!ClaudeSessionStatus.isValidSessionID(String(repeating: "a", count: 129)))
        #expect(!ClaudeSessionStatus.isValidSessionID("."))
    }
}
#endif
