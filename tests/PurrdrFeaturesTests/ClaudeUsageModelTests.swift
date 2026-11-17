#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Claude 用量(列表底部，行為規格 F18):每台主機個別同意、同意持久化、關閉時還原。
/// 主機是本機 `/bin/sh` + 暫存家目錄。
@MainActor
@Suite("Claude 用量")
struct ClaudeUsageModelTests {
    static let settings = #"{"statusLine":{"type":"command","command":"~/.claude/statusline.sh"}}"#
    let host: LocalShellHost
    let consent = InMemoryHostWriteConsentStore()

    init() throws {
        host = try LocalShellHost.temporary()
        try write(Self.settings, to: ".claude/settings.json")
    }

    func write(_ text: String, to path: String) throws {
        let url = host.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func model(hostID: String = "mac", now: Date = Date(timeIntervalSince1970: 1_738_400_000), sleep: @escaping Sleep = { _ in }) -> ClaudeUsageModel {
        ClaudeUsageModel(host: ClaudeUsageHost(channel: host), hostID: hostID, consent: consent, now: { now }, sleep: sleep)
    }

    /// 模擬 Claude Code 執行了包裝腳本、存下用量。
    func claudeReportsUsage(fiveHour: Double = 23.5, week: Double = 41.2, capturedAt: Int = 1_738_399_900) throws {
        try write(#"{"captured_at":\#(capturedAt),"status_line_input":{"rate_limits":{"five_hour":{"used_percentage":\#(fiveHour),"resets_at":1738425600},"seven_day":{"used_percentage":\#(week),"resets_at":1738857600}}}}"#,
                  to: ".purrdr/claude-usage/usage.json")
    }

    @Test("還沒同意：顯示「顯示 Claude 用量」,不碰主機")
    func offUntilConsent() async throws {
        let model = model()
        await model.refresh()

        #expect(model.state == .off)
        #expect(host.commands.isEmpty)
    }

    @Test("要求顯示：先檢查主機，再請使用者確認(說明以哪個使用者修改);確認前主機不變")
    func asksForConsentWithUser() async throws {
        let model = model()
        let before = try DirectorySnapshot(of: host.home)

        await model.requestUsage()

        #expect(model.state == .confirming(user: NSUserName()))
        #expect(try DirectorySnapshot(of: host.home) == before)
        #expect(!consent.isGranted(ClaudeUsageHost.feature.id, host: "mac"))
    }

    @Test("取消確認：回到未同意，主機不變")
    func cancelConsent() async throws {
        let model = model()
        await model.requestUsage()
        model.cancelConsent()

        #expect(model.state == .off)
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr").path))
    }

    @Test("確認後安裝包裝腳本、記住同意，Claude Code 回報後顯示用量")
    func confirmInstallsAndShowsUsage() async throws {
        let model = model()
        await model.requestUsage()
        await model.confirm()

        #expect(model.state == .on)
        #expect(consent.isGranted(ClaudeUsageHost.feature.id, host: "mac"))
        #expect(try String(contentsOf: host.url(".claude/settings.json"), encoding: .utf8).contains(ClaudeUsageHost.wrapperCommand))
        #expect(model.usage == nil)

        try claudeReportsUsage()
        await model.refresh()

        #expect(model.usage?.fiveHour?.usedPercentage == 23.5)
        #expect(model.rows.map(\.window) == [.fiveHour, .week])
    }

    @Test("同意持久化：之後(重開 app)直接讀用量，不再詢問")
    func consentPersists() async throws {
        let first = model()
        await first.requestUsage()
        await first.confirm()
        try claudeReportsUsage()

        let second = model()
        await second.refresh()

        #expect(second.state == .on)
        #expect(second.usage?.week?.usedPercentage == 41.2)
    }

    @Test("同意是每台主機各自的")
    func consentIsPerHost() async throws {
        let mac = model(hostID: "mac")
        await mac.requestUsage()
        await mac.confirm()

        #expect(model(hostID: "linux-box").state == .off)
    }

    @Test("關閉：還原主機設定(與安裝前完全相同)、撤銷同意")
    func turnOffRestoresHost() async throws {
        let before = try DirectorySnapshot(of: host.home)
        let model = model()
        await model.requestUsage()
        await model.confirm()
        try claudeReportsUsage()
        await model.refresh()

        await model.turnOff()

        #expect(model.state == .off)
        #expect(model.usage == nil)
        #expect(!consent.isGranted(ClaudeUsageHost.feature.id, host: "mac"))
        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("settings.json 不是合法 JSON:說明原因，不詢問、不修改")
    func explainsInvalidSettings() async throws {
        try write("{ \"model\": \"opus\", }", to: ".claude/settings.json")
        let before = try DirectorySnapshot(of: host.home)
        let model = model()

        await model.requestUsage()

        #expect(model.state == .off)
        #expect(model.message?.contains("isn’t valid JSON") == true)
        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("檢查後、確認前 settings.json 被改了：安裝時重新讀取，以最新內容為準")
    func installRereadsSettings() async throws {
        let model = model()
        await model.requestUsage()
        try write(#"{"model":"sonnet"}"#, to: ".claude/settings.json")

        await model.confirm()
        await model.turnOff()

        #expect(try String(contentsOf: host.url(".claude/settings.json"), encoding: .utf8) == #"{"model":"sonnet"}"#)
    }

    @Test("同意後每 5 秒讀一次用量，直到 task 取消")
    func runPollsEveryFiveSeconds() async throws {
        let sleeps = SleepLog()
        let model = model(sleep: { duration in
            await sleeps.record(duration)
            try await Task.sleep(for: .milliseconds(20))
        })
        await model.requestUsage()
        await model.confirm()
        let task = Task { await model.run() }
        defer { task.cancel() }

        try claudeReportsUsage()
        try await waitUntil { await MainActor.run { model.usage != nil } }

        #expect(await sleeps.durations.allSatisfy { $0 == .seconds(5) })
    }
}

actor SleepLog {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}
#endif

/// 用量的顯示規則(純函式，不需要主機)。
@Suite("Claude 用量顯示")
struct ClaudeUsagePresentationTests {
    static let now = Date(timeIntervalSince1970: 1_738_400_000)
    static func usage(capturedAt: TimeInterval = 1_738_399_900, fiveHourResets: TimeInterval = 1_738_425_600) -> ClaudeUsage {
        ClaudeUsage(fiveHour: .init(usedPercentage: 23.5, resetsAt: Date(timeIntervalSince1970: fiveHourResets)),
                    week: .init(usedPercentage: 41.2, resetsAt: Date(timeIntervalSince1970: 1_738_857_600)),
                    capturedAt: Date(timeIntervalSince1970: capturedAt))
    }

    @Test("預設顯示剩餘比例;切換後顯示已用比例")
    func remainingByDefaultThenUsed() {
        let remaining = ClaudeUsagePresentation.rows(for: Self.usage(), showing: .remaining, now: Self.now)
        #expect(remaining.map(\.percent) == [77, 59])
        #expect(zip(remaining.map(\.fraction), [0.765, 0.588]).allSatisfy { abs($0 - $1) < 0.0001 })

        let used = ClaudeUsagePresentation.rows(for: Self.usage(), showing: .used, now: Self.now)
        #expect(used.map(\.percent) == [24, 41])
    }

    @Test("已過重置時間的視窗不顯示")
    func hidesWindowsPastReset() {
        let rows = ClaudeUsagePresentation.rows(for: Self.usage(fiveHourResets: 1_738_399_000), showing: .remaining, now: Self.now)
        #expect(rows.map(\.window) == [.week])
    }

    @Test("擷取超過 10 分鐘才註明「截至」")
    func staleAfterTenMinutes() {
        #expect(ClaudeUsagePresentation.asOf(Self.usage(capturedAt: Self.now.timeIntervalSince1970 - 600), now: Self.now) == nil)
        let old = Self.usage(capturedAt: Self.now.timeIntervalSince1970 - 601)
        #expect(ClaudeUsagePresentation.asOf(old, now: Self.now) == old.capturedAt)
    }

    @Test("比例超出 0～100 時夾住")
    func clampsPercentages() {
        let usage = ClaudeUsage(fiveHour: .init(usedPercentage: 104, resetsAt: nil), week: .init(usedPercentage: -3, resetsAt: nil), capturedAt: Self.now)
        #expect(ClaudeUsagePresentation.rows(for: usage, showing: .remaining, now: Self.now).map(\.percent) == [0, 100])
    }
}
