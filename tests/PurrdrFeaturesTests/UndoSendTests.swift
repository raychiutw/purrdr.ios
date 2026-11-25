import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 一秒一秒手動推進的 sleep:被測物等待時停住，測試呼叫 `advance()` 才讓最早的一個等待結束。
actor SteppingSleeper {
    private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []

    nonisolated var sleep: Sleep {
        { duration in try await self.wait(duration) }
    }

    private func wait(_ duration: Duration) async throws {
        requested.append(duration)
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    var waiting: Int { waiters.count }

    /// 等到有人在等，讓最早的等待結束。
    func advance() async {
        while waiters.isEmpty { await Task.yield() }
        waiters.removeFirst().resume()
    }
}

/// 送出可撤回(#300,spec #298):送出後訊息先在本機倒數，可撤回(放回輸入框)或立即送出;秒數 0 為關閉。
@MainActor
@Suite("送出可撤回")
struct UndoSendTests {
    static func prompt(_ text: String = "整理 CSV 匯出") -> OutgoingPrompt {
        OutgoingPrompt(text: text, paneID: "w1:p6", expectedSession: "s-1", createdAt: SendPipelineTests.start)
    }

    static func clock(_ sleeper: SteppingSleeper) -> SendPipelineClock {
        SendPipelineClock(now: { SendPipelineTests.start }, sleep: sleeper.sleep)
    }

    /// 讓出主執行緒直到條件成立(倒數在背景 task 裡推進)。
    static func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
    }

    @Test("0 秒(關閉):直接通過，沒有倒數也不等待")
    func zeroSecondsPassesThrough() async {
        let sleeper = SteppingSleeper()
        let countdown = UndoSendCountdown(seconds: { 0 })

        let result = await countdown.process(Self.prompt(), clock: Self.clock(sleeper))

        #expect(result == .proceed(Self.prompt()))
        #expect(countdown.pending == nil)
        #expect(await sleeper.requested.isEmpty)
    }

    @Test("倒數中離開聊天(送出的 task 被取消):不送出、文字放回、倒數收掉")
    func cancellationHaltsWithoutSending() async throws {
        let sleeper = SteppingSleeper()
        let countdown = UndoSendCountdown(seconds: { 3 })
        let task = Task { await countdown.process(Self.prompt(), clock: Self.clock(sleeper)) }
        await Self.until { countdown.pending != nil }

        task.cancel()
        // 取消後要自己結束;沒處理取消就會一直等,以時限呈現成斷言失敗而不是掛住。
        let outcome = await boundedOutcome { await task.value }

        #expect(try outcome?.get() == .halt(SendHalt(restoresDraft: true)))
        if outcome == nil { countdown.undo() }
        #expect(countdown.pending == nil)
    }

    @Test("倒數：訊息先留在本機，每秒減一，到 0 才交給下一步")
    func countsDownThenProceeds() async {
        let sleeper = SteppingSleeper()
        let countdown = UndoSendCountdown(seconds: { 3 })
        var result: SendStepResult?
        Task { result = await countdown.process(Self.prompt(), clock: Self.clock(sleeper)) }
        await Self.until { countdown.pending != nil }

        #expect(countdown.pending == UndoSendCountdown.Pending(text: "整理 CSV 匯出", remainingSeconds: 3))
        await sleeper.advance()
        await Self.until { countdown.pending?.remainingSeconds == 2 }
        #expect(countdown.pending?.remainingSeconds == 2)
        await sleeper.advance()
        await Self.until { countdown.pending?.remainingSeconds == 1 }
        #expect(result == nil)
        await sleeper.advance()
        await Self.until { result != nil }

        #expect(result == .proceed(Self.prompt()))
        #expect(countdown.pending == nil)
        #expect(await sleeper.requested == [.seconds(1), .seconds(1), .seconds(1)])
    }

    @Test("撤回：不往下送，文字放回輸入框")
    func undoHaltsAndRestoresDraft() async {
        let sleeper = SteppingSleeper()
        let countdown = UndoSendCountdown(seconds: { 3 })
        var result: SendStepResult?
        Task { result = await countdown.process(Self.prompt(), clock: Self.clock(sleeper)) }
        await Self.until { countdown.pending != nil }

        countdown.undo()
        await Self.until { result != nil }

        #expect(result == .halt(SendHalt(restoresDraft: true)))
        #expect(countdown.pending == nil)
    }

    @Test("立即送出：不等倒數結束")
    func sendNowSkipsCountdown() async {
        let sleeper = SteppingSleeper()
        let countdown = UndoSendCountdown(seconds: { 5 })
        var result: SendStepResult?
        Task { result = await countdown.process(Self.prompt(), clock: Self.clock(sleeper)) }
        await Self.until { countdown.pending != nil }

        countdown.sendNow()
        await Self.until { result != nil }

        #expect(result == .proceed(Self.prompt()))
        #expect(countdown.pending == nil)
    }

    @Test("秒數超過範圍：最多 10 秒，負數當成關閉")
    func secondsAreClamped() async {
        #expect(UndoSendSettings.clamped(30) == 10)
        #expect(UndoSendSettings.clamped(-2) == 0)
        #expect(UndoSendSettings.clamped(4) == 4)
    }

    // MARK: - 偏好

    @Test("偏好：沒設定過是 3 秒，存了就讀回來(0–10)")
    func preferenceDefaultsToThreeSeconds() throws {
        let suite = "UndoSendTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UndoSendSettings.seconds(in: defaults) == 3)
        defaults.set(0, forKey: UndoSendSettings.secondsKey)
        #expect(UndoSendSettings.seconds(in: defaults) == 0)
        defaults.set(42, forKey: UndoSendSettings.secondsKey)
        #expect(UndoSendSettings.seconds(in: defaults) == 10)
    }

    @Test("設定頁調整撤回秒數：存進偏好")
    func settingsStoresSeconds() throws {
        let suite = "UndoSendTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsModelTests.model(defaults: defaults)

        #expect(settings.undoSendSeconds == 3)
        settings.undoSendSeconds = 7
        #expect(UndoSendSettings.seconds(in: defaults) == 7)
    }

    // MARK: - 聊天輸入列

    /// 聊天的等待一律不結束：倒數只靠撤回或立即送出結束。
    static func openedWithCountdown(_ countdown: UndoSendCountdown) async throws -> ConversationSendTests.Setup {
        try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts, sendStages: SendStages(undo: countdown), sleep: RecordingSleeper().sleep)
        }
    }

    @Test("聊天：倒數期間什麼都沒送、沒有回音;撤回後文字放回輸入框")
    func conversationUndoRestoresDraft() async throws {
        let countdown = UndoSendCountdown(seconds: { 3 })
        let setup = try await Self.openedWithCountdown(countdown)
        setup.model.draft = "先別送"

        let sending = Task { await setup.model.send() }
        await Self.until { countdown.pending != nil }
        #expect(setup.model.undoSend === countdown)
        #expect(setup.model.draft == "")
        #expect(setup.model.echoes.isEmpty)
        countdown.undo()
        await sending.value

        #expect(await ConversationSendTests.promptRequests(setup).isEmpty)
        #expect(setup.model.echoes.isEmpty)
        #expect(setup.model.draft == "先別送")
    }

    @Test("聊天：倒數期間又打了字，撤回時原文放在前面，不蓋掉新打的")
    func conversationUndoKeepsNewTyping() async throws {
        let countdown = UndoSendCountdown(seconds: { 3 })
        let setup = try await Self.openedWithCountdown(countdown)
        setup.model.draft = "第一段"

        let sending = Task { await setup.model.send() }
        await Self.until { countdown.pending != nil }
        setup.model.draft = "補充"
        countdown.undo()
        await sending.value

        #expect(setup.model.draft == "第一段\n補充")
    }

    @Test("聊天：立即送出就交給主機，出現回音")
    func conversationSendNowDelivers() async throws {
        let countdown = UndoSendCountdown(seconds: { 3 })
        let setup = try await Self.openedWithCountdown(countdown)
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.delivered)
        setup.model.draft = "現在就送"

        let sending = Task { await setup.model.send() }
        await Self.until { countdown.pending != nil }
        countdown.sendNow()
        await sending.value

        #expect(await ConversationSendTests.promptRequests(setup).count == 1)
        #expect(setup.model.echoes.map(\.text) == ["現在就送"])
    }
}
