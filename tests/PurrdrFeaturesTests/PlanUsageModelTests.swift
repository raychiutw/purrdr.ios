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
        consent.grant(ClaudePlanUsageHost.feature.id, host: selection.storedValue)
    }

    static let bothHosts = [HostOption(id: mac, name: "Mac"), HostOption(id: linux, name: "Linux")]

    /// 這些測試的百分比以「剩餘」為準(預設已用,#420):每次一份獨立、已存「剩餘」的 defaults。
    static func remainingDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "plan-usage-\(UUID().uuidString)")!
        PlanUsageModel.Display.remaining.store(in: defaults)
        return defaults
    }

    func model(
        hosts: [HostOption] = Self.bothHosts, store: any PlanUsageSelectionStore = InMemoryPlanUsageSelectionStore(),
        channel: (any HostChannel)? = nil, cost: PlanUsageQueryCost = .transfer, sleep: @escaping Sleep = StepSleeper().sleep,
        unsupported: Set<HostSelection> = [], enabledAgents: @escaping (HostSelection) -> Set<AgentID> = { _ in Set(HostAgentSettings.configurable) }
    ) -> PlanUsageModel {
        let channel = channel ?? host
        let consent = consent
        return PlanUsageModel(
            hosts: hosts, fallback: Self.mac, store: store, now: { Self.now }, sleep: sleep, defaults: Self.remainingDefaults(),
            enabledAgents: enabledAgents
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
        model.select(agent: .claude)
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
        #expect(reopened.agent == .claude)

        let linuxDeleted = model(hosts: [HostOption(id: Self.mac, name: "Mac")], store: store)
        #expect(linuxDeleted.host == Self.mac)
    }

    // MARK: 只列這台主機啟用的 Agent(#477)

    @Test("Agent 清單只有這台主機啟用的")
    func listsOnlyEnabledAgents() {
        let model = model(enabledAgents: { $0 == Self.mac ? [.claude] : [.codex, .agy] })
        #expect(model.agents == [.claude])
        model.select(host: Self.linux)
        #expect(model.agents == [.codex, .agy])
    }

    @Test("上次選的 Agent 這台主機沒啟用:改選第一個啟用的")
    func savedAgentNotEnabledFallsBack() {
        let store = InMemoryPlanUsageSelectionStore()
        store.save(PlanUsageSelection(host: Self.mac, agent: .codex))
        let model = model(store: store, enabledAgents: { _ in [.claude] })
        #expect(model.agent == .claude)
    }

    @Test("換到沒啟用目前 Agent 的主機:Agent 跟著換")
    func switchingHostReselectsAgent() {
        let model = model(enabledAgents: { $0 == Self.mac ? [.claude, .codex] : [.agy] })
        model.select(agent: .codex)
        model.select(host: Self.linux)
        #expect(model.agent == .agy)
    }

    @Test("這台主機一個 Agent 都沒啟用:不查詢,說明沒有可看的 Agent")
    func noAgentEnabled() async {
        let model = model(enabledAgents: { _ in [] })
        model.appeared()
        await model.untilIdle()
        #expect(model.agents.isEmpty)
        #expect(model.state == .noAgentEnabled)
        #expect(host.commands.isEmpty)
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
        #expect(model.state == .failed(.connection(DisplayedError(error: SSHConnectionError.timedOut))))

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

    @Test("回到前景：只有從背景回來才再查一次;拉下控制中心(inactive → active)不查")
    func returningFromBackgroundQueriesAgain() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let model = model()
        model.appeared()
        await model.untilIdle()

        model.becameActive()
        await model.untilIdle()
        #expect(host.commands.count == 1)

        model.enteredBackground()
        model.becameActive()
        await model.untilIdle()
        #expect(host.commands.count == 2)
    }

    @Test("進背景：進行中的查詢被取消;畫面不在時回到前景不查")
    func backgroundStopsQueryAndHiddenScreenStaysIdle() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let gated = GatedChannel(base: host)
        let model = model(channel: gated)
        model.appeared()
        #expect(await gated.waitUntilWaiting())

        model.enteredBackground()
        await gated.open()
        await host.waitUntilFinished()
        #expect(await stays(model.state == .loading))

        model.disappeared()
        model.becameActive()
        #expect(await stays(host.commands.count == 1))
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

    // MARK: - Codex(#178)

    static let codexRateLimits = #"""
        {"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":23,"windowDurationMins":300,"resetsAt":1738425600},"secondary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1738857600}}}}
        """#

    /// Claude 讀本機 `/bin/sh` 主機(未同意);Codex 讀 `codex` 通道。
    func model(codex: any HostChannel, codexSleep: @escaping Sleep = Sleeping.task) -> PlanUsageModel {
        let claudeChannel = host
        let consent = consent
        return PlanUsageModel(hosts: Self.bothHosts, fallback: Self.mac, store: InMemoryPlanUsageSelectionStore(), now: { Self.now }, defaults: Self.remainingDefaults()) { selection, agent in
            switch agent {
            case .claude: .claude(channel: claudeChannel, cost: .transfer, hostID: selection.storedValue, consent: consent)
            case .codex: .codex(channel: codex, cost: .transfer, sleep: codexSleep)
            default: nil
            }
        }
    }

    @Test("切到 Codex:不要求同意、不寫主機，查一次就顯示 5 小時與每週;查詢需要傳輸")
    func codexNeedsNoConsent() async throws {
        let codex = await FakeCodexAppServer.host(answering: Self.codexRateLimits)
        let model = model(codex: codex)
        model.appeared()
        await model.untilIdle()
        #expect(model.state == .needsConsent)

        model.select(agent: .codex)
        await model.untilIdle()

        #expect(model.rows.map(\.period) == [.fiveHour, .week])
        #expect(model.rows.map(\.percent) == [77, 59])
        #expect(model.cost == .transfer)
        #expect(!model.canTurnOff)
        #expect(await codex.executions.map(\.command) == [CodexPlanUsageHost.command])
        #expect(host.commands.isEmpty)
    }

    @Test("Codex 的錯誤各有原因：找不到 codex、未登入、逾時、回應無法解析、查詢失敗(帶 app-server 的說明)")
    func codexErrorsHaveReasons() async throws {
        let notFound = FakeHost()
        await notFound.expect(CodexPlanUsageHost.command, reply: FakeReply(exitCode: 127))
        let signedOut = await FakeCodexAppServer.host(
            answering: #"{"id":1,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}"#)
        let silent = await FakeCodexAppServer.host(answering: nil)
        let unreadable = await FakeCodexAppServer.host(answering: #"{"id":1,"result":{}}"#)
        let failing = await FakeCodexAppServer.host(
            answering: #"{"id":1,"error":{"code":-32603,"message":"failed to fetch codex rate limits: timeout"}}"#)
        let immediately: Sleep = { _ in }
        let cases: [(any HostChannel, Sleep, PlanUsageFailure)] = [
            (notFound, Sleeping.task, .codexNotFound),
            (signedOut, Sleeping.task, .codexNotSignedIn),
            (silent, immediately, .codexTimedOut),
            (unreadable, Sleeping.task, .codexUnreadableResponse),
            (failing, Sleeping.task, .codexRequestFailed("failed to fetch codex rate limits: timeout")),
        ]
        for (channel, sleep, expected) in cases {
            let model = model(codex: channel, codexSleep: sleep)
            model.select(agent: .codex)
            await model.untilIdle()
            #expect(model.state == .failed(expected))
        }
    }

    // MARK: - Claude 的同意、確認、關閉並還原(每台主機各自同意)

    @Test("Claude 還沒同意：顯示需要同意，不碰主機")
    func needsConsentBeforeReading() async throws {
        let model = model()

        model.appeared()
        await model.untilIdle()

        #expect(model.state == .needsConsent)
        #expect(host.commands.isEmpty)
    }

    @Test("要求顯示：先檢查主機，再請使用者確認(說明以哪個使用者修改);確認前主機不變")
    func asksForConsentWithUser() async throws {
        let model = model()
        model.appeared()
        let before = try DirectorySnapshot(of: host.home)

        await model.requestConsent()

        #expect(model.state == .confirming(user: NSUserName()))
        #expect(try DirectorySnapshot(of: host.home) == before)
        #expect(!consent.isGranted(ClaudePlanUsageHost.feature.id, host: Self.mac.storedValue))
    }

    @Test("取消確認：回到需要同意，主機不變")
    func cancelConsent() async throws {
        let model = model()
        model.appeared()
        await model.requestConsent()

        model.cancelConsent()

        #expect(model.state == .needsConsent)
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr").path))
    }

    @Test("確認：安裝包裝腳本、記住同意後查一次;Claude Code 回報後下拉就有數字")
    func confirmInstallsAndQueries() async throws {
        let model = model()
        model.appeared()
        await model.requestConsent()

        await model.confirm()

        #expect(model.state == .noData)
        #expect(consent.isGranted(ClaudePlanUsageHost.feature.id, host: Self.mac.storedValue))
        #expect(try String(contentsOf: host.url(".claude/settings.json"), encoding: .utf8).contains(ClaudePlanUsageHost.wrapperCommand))

        try claudeReportsUsage()
        await model.refresh()
        #expect(model.rows.map(\.period) == [.fiveHour, .week])
    }

    @Test("同意是每台主機各自的")
    func consentIsPerHost() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let model = model()
        model.appeared()
        await model.untilIdle()

        model.select(host: Self.linux)
        await model.untilIdle()

        #expect(model.state == .needsConsent)
    }

    @Test("關閉：還原主機設定(與安裝前完全相同)、撤銷同意")
    func turnOffRestoresHost() async throws {
        let before = try DirectorySnapshot(of: host.home)
        let model = model()
        model.appeared()
        await model.requestConsent()
        await model.confirm()
        try claudeReportsUsage()
        await model.refresh()

        await model.turnOff()

        #expect(model.state == .needsConsent)
        #expect(!consent.isGranted(ClaudePlanUsageHost.feature.id, host: Self.mac.storedValue))
        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("已裝舊版包裝(#388):提示更新,不靜默覆寫;確認後換成新腳本,取消則維持原樣")
    func oldWrapperPromptsUpdate() async throws {
        let model = model()
        model.appeared()
        await model.requestConsent()
        await model.confirm()
        try claudeReportsUsage()
        await model.refresh()
        #expect(!model.wrapperUpdateAvailable)

        // 模擬舊版 app 裝的腳本(內容不同)。
        let wrapper = host.home.appending(path: ".purrdr/claude-usage/statusline.sh")
        try Data("#!/bin/sh\n# old wrapper\n".utf8).write(to: wrapper)
        await model.refresh()
        #expect(model.wrapperUpdateAvailable)
        #expect(try String(contentsOf: wrapper, encoding: .utf8) == "#!/bin/sh\n# old wrapper\n", "只提示,不能自己覆寫")

        await model.requestWrapperUpdate()
        guard case .confirming = model.state else { Issue.record("沒有請使用者確認:\(model.state)"); return }
        model.cancelConsent()
        await model.untilIdle()
        #expect(model.state != .needsConsent)
        #expect(try String(contentsOf: wrapper, encoding: .utf8) == "#!/bin/sh\n# old wrapper\n")

        await model.requestWrapperUpdate()
        await model.confirm()
        await model.untilIdle()
        #expect(!model.wrapperUpdateAvailable)
        #expect(try String(contentsOf: wrapper, encoding: .utf8).contains("sessions"))
    }

    @Test("settings.json 不是合法 JSON:說明原因，不詢問、不修改")
    func explainsInvalidSettings() async throws {
        try host.write(Data("{ \"model\": \"opus\", }".utf8), to: ".claude/settings.json")
        let before = try DirectorySnapshot(of: host.home)
        let model = model()
        model.appeared()

        await model.requestConsent()

        #expect(model.state == .needsConsent)
        #expect(model.message?.text.contains("are damaged") == true)
        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("檢查後、確認前 settings.json 被改了：安裝時重新讀取，以最新內容為準")
    func installRereadsSettings() async throws {
        let model = model()
        model.appeared()
        await model.requestConsent()
        try host.write(Data(#"{"model":"sonnet"}"#.utf8), to: ".claude/settings.json")

        await model.confirm()
        await model.turnOff()

        #expect(try String(contentsOf: host.url(".claude/settings.json"), encoding: .utf8) == #"{"model":"sonnet"}"#)
    }

    @Test("等使用者確認時，自動重整與下拉都不打斷確認")
    func refreshDoesNotInterruptConsent() async throws {
        let sleeper = StepSleeper()
        let model = model(cost: .free, sleep: sleeper.sleep)
        model.appeared()
        await model.requestConsent()

        try await waitUntil { await sleeper.waitingCount == 1 }
        await sleeper.step()
        await model.refresh()

        #expect(await stays(model.state == .confirming(user: NSUserName())))
    }

    @Test("不耗 token 與傳輸的來源：關閉後再同意，畫面開著時照樣定期重整")
    func freeSourceKeepsRefreshingAfterTurningOffAndOn() async throws {
        let sleeper = StepSleeper()
        let model = model(cost: .free, sleep: sleeper.sleep)
        model.appeared()
        await model.requestConsent()
        await model.confirm()
        await model.turnOff()
        await model.requestConsent()
        await model.confirm()
        let reads = host.commands.count

        try claudeReportsUsage()
        try await waitUntil { await sleeper.waitingCount == 1 }
        await sleeper.step()

        try await waitUntil { await MainActor.run { model.rows.count == 2 } }
        #expect(host.commands.count == reads + 1)
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

    @Test("圓環顏色依已用比例分三級：70% 起偏高、85% 起將用完;與顯示剩餘或已用無關")
    func levelFollowsUsed() {
        let usage = Self.usage(fiveHourUsed: 70, weekUsed: 85)
        #expect(PlanUsagePresentation.rows(for: usage, showing: .remaining, now: Self.now).map(\.level) == [.low, .depleted])
        #expect(PlanUsagePresentation.rows(for: usage, showing: .used, now: Self.now).map(\.level) == [.low, .depleted])
        let ample = Self.usage(fiveHourUsed: 69, weekUsed: 84)
        #expect(PlanUsagePresentation.rows(for: ample, showing: .remaining, now: Self.now).map(\.level) == [.ample, .low])
    }
}

/// 同一用量週期依模型群組多份(Antigravity,#448):標題與主機 tab 只顯示目前模型的群組,詳細面板全列。
@Suite("方案用量多群組")
struct PlanUsageGroupsTests {
    static let now = Date(timeIntervalSince1970: 1_738_400_000)
    static func usage(activeGroup: PlanUsage.Group? = nil) -> PlanUsage {
        func period(_ kind: PlanUsage.Period.Kind, _ group: PlanUsage.Group, used: Double) -> PlanUsage.Period {
            .init(kind: kind, group: group, usedPercentage: used, resetsAt: now.addingTimeInterval(3_600))
        }
        return PlanUsage(
            periods: [
                period(.fiveHour, .gemini, used: 10), period(.week, .gemini, used: 20),
                period(.fiveHour, .thirdParty, used: 30), period(.week, .thirdParty, used: 40),
            ], capturedAt: now, activeGroup: activeGroup)
    }

    @Test("標題與主機 tab 只顯示目前模型的群組")
    func compactShowsActiveGroupOnly() {
        let gemini = PlanUsagePresentation.rows(for: Self.usage(activeGroup: .gemini), showing: .used, now: Self.now)
        #expect(gemini.map(\.percent) == [10, 20])
        #expect(gemini.map(\.group) == [.gemini, .gemini])
        let thirdParty = PlanUsagePresentation.rows(for: Self.usage(activeGroup: .thirdParty), showing: .used, now: Self.now)
        #expect(thirdParty.map(\.percent) == [30, 40])
    }

    @Test("聊天的目前模型優先於檔案裡最後一個 session 的模型")
    func overrideBeatsStoredGroup() {
        let rows = PlanUsagePresentation.rows(for: Self.usage(activeGroup: .gemini), showing: .used, now: Self.now, activeGroup: .thirdParty)
        #expect(rows.map(\.percent) == [30, 40])
    }

    @Test("不知道目前模型時顯示第一個群組(不會兩組混在一起)")
    func unknownActiveGroupShowsFirstGroup() {
        let rows = PlanUsagePresentation.rows(for: Self.usage(), showing: .used, now: Self.now)
        #expect(rows.map(\.group) == [.gemini, .gemini])
    }

    @Test("詳細面板兩個群組都列,已用／剩餘照設定")
    func detailListsEveryGroup() {
        let used = PlanUsagePresentation.rows(for: Self.usage(activeGroup: .gemini), showing: .used, now: Self.now, allGroups: true)
        #expect(used.map(\.percent) == [10, 20, 30, 40])
        let remaining = PlanUsagePresentation.rows(for: Self.usage(activeGroup: .gemini), showing: .remaining, now: Self.now, allGroups: true)
        #expect(remaining.map(\.percent) == [90, 80, 70, 60])
        #expect(Set(used.map(\.id)).count == 4, "兩個群組的同一週期識別碼不能相同")
    }

    @Test("只有一個群組(Claude、Codex)時照舊,不受群組篩選影響")
    func singleGroupUnchanged() {
        let usage = PlanUsage(
            periods: [.init(kind: .fiveHour, usedPercentage: 12, resetsAt: nil), .init(kind: .week, usedPercentage: 34, resetsAt: nil)],
            capturedAt: Self.now)
        #expect(PlanUsagePresentation.rows(for: usage, showing: .used, now: Self.now).map(\.percent) == [12, 34])
    }

    @Test("模型名稱換成群組:Gemini 開頭是 Gemini,其他是第三方,空的沒有")
    func groupFromModelName() {
        #expect(PlanUsage.Group(modelName: "Gemini 4 Neon (Medium)") == .gemini)
        #expect(PlanUsage.Group(modelName: "gemini-4-argon") == .gemini)
        #expect(PlanUsage.Group(modelName: "Claude Sonnet 5") == .thirdParty)
        #expect(PlanUsage.Group(modelName: "GPT-OSS 120B") == .thirdParty)
        #expect(PlanUsage.Group(modelName: "  ") == nil)
    }
}
