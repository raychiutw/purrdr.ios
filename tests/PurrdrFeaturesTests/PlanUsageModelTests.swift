#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 方案用量畫面(#177):選主機與 Agent 後查詢。主機是本機 `/bin/sh` + 暫存家目錄(LocalShellHost)。
@MainActor
@Suite("方案用量畫面")
struct PlanUsageModelTests {
    static let settings = #"{"statusLine":{"type":"command","command":"~/.claude/statusline.sh"}}"#
    static let mac = HostSelection.host(UUID(uuidString: "6F1C2A4E-0B7D-4C1E-9A55-0D2C8E1F3A10")!)
    static let linux = HostSelection.host(UUID(uuidString: "1A2B3C4D-5E6F-4A1B-8C2D-3E4F5A6B7C8D")!)
    static let now = Date(timeIntervalSince1970: 1_738_400_000)

    let host: LocalShellHost
    let consent = InMemoryHostWriteConsentStore()

    init() throws {
        host = try LocalShellHost.temporary()
        try host.write(Data(Self.settings.utf8), to: ".claude/settings.json")
    }

    /// 模擬 Claude Code 執行了包裝腳本、存下用量。
    func claudeReportsUsage(fiveHour: Double = 23.5, week: Double = 41.2, capturedAt: Int = 1_738_399_900) throws {
        try host.write(Data(#"{"captured_at":\#(capturedAt),"status_line_input":{"rate_limits":{"five_hour":{"used_percentage":\#(fiveHour),"resets_at":1738425600},"seven_day":{"used_percentage":\#(week),"resets_at":1738857600}}}}"#.utf8),
                       to: ".purrdr/claude-usage/usage.json")
    }

    func grantClaudeUsage(on selection: HostSelection = Self.mac) {
        consent.grant(ClaudeUsageHost.feature.id, host: selection.storedValue)
    }

    static let bothHosts = [PlanUsageHostOption(id: mac, name: "Mac"), PlanUsageHostOption(id: linux, name: "Linux")]

    func model(
        hosts: [PlanUsageHostOption] = Self.bothHosts, store: any PlanUsageSelectionStore = InMemoryPlanUsageSelectionStore(),
        channel: (any HostChannel)? = nil, cost: PlanUsageQueryCost = .transfer, sleep: @escaping Sleep = StepSleeper().sleep,
        unsupported: Set<HostSelection> = []
    ) -> PlanUsageModel {
        let channel = channel ?? host
        let consent = consent
        return PlanUsageModel(
            hosts: hosts, fallback: Self.mac, store: store, now: { Self.now }, sleep: sleep
        ) { selection, _ in
            guard !unsupported.contains(selection) else { return nil }
            return .claude(channel: channel, cost: cost, hostID: selection.storedValue, consent: consent)
        }
    }

    @Test("打開畫面：依選擇查一次，顯示 5 小時與每週用量週期")
    func appearingQueriesOnce() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let model = model()

        model.appeared()
        await model.untilIdle()

        #expect(model.rows.map(\.period) == [.fiveHour, .week])
        #expect(model.rows.map(\.percent) == [77, 59])
        #expect(host.commands.count == 1)
    }

    @Test("改選主機或 Agent 才重新查詢;選回同一個不查")
    func changingSelectionQueriesAgain() async throws {
        grantClaudeUsage()
        grantClaudeUsage(on: Self.linux)
        try claudeReportsUsage()
        let model = model()
        model.appeared()
        await model.untilIdle()

        model.select(host: Self.linux)
        await model.untilIdle()
        #expect(model.host == Self.linux)
        #expect(host.commands.count == 2)

        model.select(host: Self.linux)
        model.select(agent: .claudeCode)
        await model.untilIdle()
        #expect(host.commands.count == 2)
    }

    @Test("記住上次選的主機與 Agent;那台主機被刪除時退回選取中主機")
    func remembersSelection() async throws {
        let store = InMemoryPlanUsageSelectionStore()
        let first = model(store: store)
        first.select(host: Self.linux)

        let reopened = model(store: store)
        #expect(reopened.host == Self.linux)
        #expect(reopened.agent == .claudeCode)

        let linuxDeleted = model(hosts: [PlanUsageHostOption(id: Self.mac, name: "Mac")], store: store)
        #expect(linuxDeleted.host == Self.mac)
    }

    @Test("連線方式不支援(HTTPS 主機):直接說明，不連線")
    func unsupportedConnectionDoesNotConnect() async throws {
        grantClaudeUsage()
        let model = model(unsupported: [Self.mac])

        model.appeared()
        await model.untilIdle()

        #expect(model.state == .unsupportedConnection)
        #expect(host.commands.isEmpty)
    }

    @Test("Claude Code 還沒回報過：顯示尚無資料")
    func noDataBeforeClaudeReports() async throws {
        grantClaudeUsage()
        let model = model()

        model.appeared()
        await model.untilIdle()

        #expect(model.state == .noData)
    }

    @Test("連不上主機：顯示連線錯誤，下拉可重試")
    func unreachableHostCanRetry() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let unreachable = FakeHost()
        await unreachable.failConnection(with: SSHConnectionError.timedOut)
        let gate = RoutingSwitch(unreachable: unreachable, reachable: host)
        let model = model(channel: gate)

        model.appeared()
        await model.untilIdle()
        #expect(model.state == .failed("The host didn’t answer in time. Make sure it’s awake and both devices are on your tailnet."))

        await gate.connect()
        await model.refresh()
        #expect(model.rows.count == 2)
    }

    @Test("下拉重新整理：再查一次，拿到最新數字")
    func pullToRefreshQueriesAgain() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let model = model()
        model.appeared()
        await model.untilIdle()

        try claudeReportsUsage(fiveHour: 50)
        await model.refresh()

        #expect(host.commands.count == 2)
        #expect(model.rows.first?.percent == 50)
    }

    @Test("查詢進行中連按下拉：只送出一個查詢")
    func repeatedPullsShareOneQuery() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let gated = GatedChannel(base: host)
        let model = model(channel: gated)
        model.appeared()
        #expect(await gated.waitUntilWaiting())

        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        await gated.open()
        _ = await (first, second)

        #expect(host.commands.count == 1)
        #expect(model.rows.count == 2)
    }

    @Test("離開畫面：進行中的查詢被取消，結果不再顯示")
    func disappearingCancelsQuery() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let gated = GatedChannel(base: host)
        let model = model(channel: gated)
        model.appeared()
        #expect(await gated.waitUntilWaiting())

        model.disappeared()
        await gated.open()
        await host.waitUntilFinished()

        #expect(await stays(model.state == .loading))
    }

    @Test("需要傳輸的來源：畫面開著也不定時重整")
    func transferSourcesNeverPoll() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let sleeper = StepSleeper()
        let model = model(cost: .transfer, sleep: sleeper.sleep)

        model.appeared()
        await model.untilIdle()

        #expect(await stays(host.commands.count == 1))
        #expect(await sleeper.requested.isEmpty)
    }

    @Test("不耗 token 也不耗傳輸的來源(Demo):畫面開著時定期重整，離開畫面就停")
    func freeSourcesRefreshWhileVisible() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let sleeper = StepSleeper()
        let model = model(cost: .free, sleep: sleeper.sleep)
        model.appeared()
        await model.untilIdle()

        try claudeReportsUsage(fiveHour: 50)
        try await waitUntil { await sleeper.waitingCount == 1 }
        await sleeper.step()
        try await waitUntil { await MainActor.run { model.rows.first?.percent == 50 } }
        #expect(host.commands.count == 2)

        model.disappeared()
        await sleeper.step()
        #expect(await stays(host.commands.count == 2))
    }

    /// 在一小段時間內條件一直成立(斷言「不會發生」用)。
    func stays(_ condition: @autoclosure @MainActor () -> Bool) async -> Bool {
        for _ in 0..<20 {
            guard condition() else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// 先連不上，`connect()` 之後交給可連線的通道。
actor RoutingSwitch: HostChannel {
    let unreachable: any HostChannel
    let reachable: any HostChannel
    private var isConnected = false

    init(unreachable: any HostChannel, reachable: any HostChannel) {
        self.unreachable = unreachable
        self.reachable = reachable
    }

    func connect() { isConnected = true }

    func execute(_ command: String) async throws -> any ExecSession {
        try await (isConnected ? reachable : unreachable).execute(command)
    }

    func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        try await (isConnected ? reachable : unreachable).openPTY(request)
    }

    func disconnect() async {}
}

/// 每次等待都卡住，直到 `step()`(時間到)或所在的 task 被取消。
actor StepSleeper {
    private(set) var requested: [Duration] = []
    private var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextID = 0

    var waitingCount: Int { waiting.count }

    nonisolated var sleep: Sleep {
        { duration in try await self.wait(duration) }
    }

    /// 時間到：目前在等的全部醒來。
    func step() {
        let resumed = waiting
        waiting = [:]
        resumed.values.forEach { $0.resume() }
    }

    private func wait(_ duration: Duration) async throws {
        requested.append(duration)
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                register(continuation, id: id)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, any Error>, id: Int) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            waiting[id] = continuation
        }
    }

    private func cancel(_ id: Int) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
#endif

/// 方案用量的顯示規則(純函式，不需要主機;沿用原本 Claude 用量的規則)。
@Suite("方案用量顯示")
struct PlanUsagePresentationTests {
    static let now = Date(timeIntervalSince1970: 1_738_400_000)
    static func usage(
        fiveHourUsed: Double = 23.5, weekUsed: Double = 41.2, capturedAt: TimeInterval = 1_738_399_900,
        fiveHourResets: TimeInterval? = 1_738_425_600
    ) -> PlanUsage {
        PlanUsage(
            periods: [
                .init(kind: .fiveHour, usedPercentage: fiveHourUsed, resetsAt: fiveHourResets.map { Date(timeIntervalSince1970: $0) }),
                .init(kind: .week, usedPercentage: weekUsed, resetsAt: Date(timeIntervalSince1970: 1_738_857_600)),
            ],
            capturedAt: Date(timeIntervalSince1970: capturedAt))
    }

    @Test("預設顯示剩餘比例;切換後顯示已用比例")
    func remainingByDefaultThenUsed() {
        let remaining = PlanUsagePresentation.rows(for: Self.usage(), showing: .remaining, now: Self.now)
        #expect(remaining.map(\.percent) == [77, 59])
        #expect(zip(remaining.map(\.fraction), [0.765, 0.588]).allSatisfy { abs($0 - $1) < 0.0001 })

        let used = PlanUsagePresentation.rows(for: Self.usage(), showing: .used, now: Self.now)
        #expect(used.map(\.percent) == [24, 41])
    }

    @Test("已過重置時間的用量週期不顯示")
    func hidesPeriodsPastReset() {
        let rows = PlanUsagePresentation.rows(for: Self.usage(fiveHourResets: 1_738_399_000), showing: .remaining, now: Self.now)
        #expect(rows.map(\.period) == [.week])
    }

    @Test("擷取超過 10 分鐘才註明「截至」")
    func staleAfterTenMinutes() {
        #expect(PlanUsagePresentation.asOf(Self.usage(capturedAt: Self.now.timeIntervalSince1970 - 600), now: Self.now) == nil)
        let old = Self.usage(capturedAt: Self.now.timeIntervalSince1970 - 601)
        #expect(PlanUsagePresentation.asOf(old, now: Self.now) == old.capturedAt)
    }

    @Test("比例超出 0～100 時夾住")
    func clampsPercentages() {
        let usage = Self.usage(fiveHourUsed: 104, weekUsed: -3, fiveHourResets: nil)
        #expect(PlanUsagePresentation.rows(for: usage, showing: .remaining, now: Self.now).map(\.percent) == [0, 100])
    }

    @Test("圓環顏色依剩餘比例分三級：超過 40% 充足、超過 15% 偏低、其餘將用完;與顯示剩餘或已用無關")
    func levelFollowsRemaining() {
        let usage = Self.usage(fiveHourUsed: 60, weekUsed: 85)
        #expect(PlanUsagePresentation.rows(for: usage, showing: .remaining, now: Self.now).map(\.level) == [.low, .depleted])
        #expect(PlanUsagePresentation.rows(for: usage, showing: .used, now: Self.now).map(\.level) == [.low, .depleted])
        let ample = Self.usage(fiveHourUsed: 59, weekUsed: 84)
        #expect(PlanUsagePresentation.rows(for: ample, showing: .remaining, now: Self.now).map(\.level) == [.ample, .low])
    }
}
