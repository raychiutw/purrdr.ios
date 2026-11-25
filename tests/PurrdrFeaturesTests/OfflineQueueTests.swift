import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 離線佇列(#301,spec #298):沒有連線時送出的訊息先排隊(每台主機最多 30 則，存本機);
/// 重連後收到第一次 Agent 列表時，pane 與 session 都沒變且排隊不到 10 分鐘才補送，否則標示原因、可放回輸入框。
@MainActor
@Suite("離線佇列")
struct OfflineQueueTests {
    nonisolated static let start = Date(timeIntervalSince1970: 1_794_614_400)
    static let host = "demo"

    /// 可以手動推進的現在時間。
    final class Now: @unchecked Sendable {
        var value = OfflineQueueTests.start
        var clock: @Sendable () -> Date { { self.value } }
    }

    /// 記下補送的內容，回應指定的結果。
    @MainActor
    final class Deliveries {
        var sent: [(text: String, paneID: String, expectedSession: String?)] = []
        var outcome: PromptOutcome = .delivered

        var deliver: @MainActor (String, Agent, String?) async -> PromptOutcome {
            { text, agent, expectedSession in
                self.sent.append((text, agent.paneID, expectedSession))
                return self.outcome
            }
        }
    }

    static func prompt(_ text: String = "整理 CSV 匯出", pane: String = "w1:p6", session: String? = "s-1", at date: Date = start) -> OutgoingPrompt {
        OutgoingPrompt(text: text, paneID: pane, expectedSession: session, createdAt: date, workspaceID: "w1")
    }

    static func snapshot(pane: String = "w1:p6", workspace: String = "w1", session: String? = "s-1", status: AgentStatus = .idle) -> HostSnapshot {
        HostSnapshot(version: "0.9.5", agents: [
            Agent(paneID: pane, workspaceID: workspace, kind: "claude", status: status,
                  session: session.map { AgentSessionReference(kind: "id", value: $0) })
        ])
    }

    static func queue(
        store: any OfflineQueueStore = InMemoryOfflineQueueStore(), now: Now = Now(), deliveries: Deliveries = Deliveries()
    ) -> OfflineQueue {
        OfflineQueue(host: host, store: store, now: now.clock, deliver: deliveries.deliver)
    }

    @Test("補送帶排入時的 session(HTTPS 主機在送出前比對)")
    func deliveryCarriesQueuedSession() async {
        let deliveries = Deliveries()
        let queue = Self.queue(deliveries: deliveries)
        queue.enqueue(Self.prompt("帶 session", session: "s-1"))

        await queue.reconcile(with: Self.snapshot())

        #expect(deliveries.sent.map(\.expectedSession) == ["s-1"])
    }

    @Test("重連後的 Agent 列表：pane 與 session 都沒變、不到 10 分鐘，依序補送並移出佇列")
    func reconcileDeliversMatchingPrompts() async {
        let now = Now()
        let deliveries = Deliveries()
        let queue = Self.queue(now: now, deliveries: deliveries)
        #expect(queue.enqueue(Self.prompt("第一則")))
        #expect(queue.enqueue(Self.prompt("第二則")))
        #expect(queue.entries.map(\.text) == ["第一則", "第二則"])

        now.value = Self.start.addingTimeInterval(9 * 60 + 59)
        await queue.reconcile(with: Self.snapshot())

        #expect(deliveries.sent.map(\.text) == ["第一則", "第二則"])
        #expect(deliveries.sent.map(\.paneID) == ["w1:p6", "w1:p6"])
        #expect(queue.entries.isEmpty)
    }

    @Test("排隊滿 10 分鐘：不補送，標示「排隊超過 10 分鐘」、留在佇列等使用者處理")
    func expiredPromptsAreNotSent() async {
        let now = Now()
        let deliveries = Deliveries()
        let queue = Self.queue(now: now, deliveries: deliveries)
        queue.enqueue(Self.prompt("太久了"))
        queue.enqueue(Self.prompt("還來得及", at: Self.start.addingTimeInterval(60)))

        now.value = Self.start.addingTimeInterval(10 * 60)
        await queue.reconcile(with: Self.snapshot())

        #expect(deliveries.sent.map(\.text) == ["還來得及"])
        #expect(queue.entries.map(\.text) == ["太久了"])
        #expect(queue.entries.first?.problem == .expired)
    }

    @Test("session 換了：不補送，標示「對話已變更」")
    func changedSessionIsNotSent() async {
        let deliveries = Deliveries()
        let queue = Self.queue(deliveries: deliveries)
        queue.enqueue(Self.prompt("給舊的 session"))

        await queue.reconcile(with: Self.snapshot(session: "s-2"))

        #expect(deliveries.sent.isEmpty)
        #expect(queue.entries.first?.problem == .conversationChanged)
    }

    @Test("pane 不在了或換到別的 Workspace:不補送，標示「對話已變更」")
    func changedPaneIsNotSent() async {
        let deliveries = Deliveries()
        let queue = Self.queue(deliveries: deliveries)
        queue.enqueue(Self.prompt("給 w1:p6"))
        queue.enqueue(Self.prompt("給 w1:p7", pane: "w1:p7"))

        await queue.reconcile(with: Self.snapshot(workspace: "w2"))

        #expect(deliveries.sent.isEmpty)
        #expect(queue.entries.map(\.problem) == [.conversationChanged, .conversationChanged])
    }

    @Test("比對只在重連後的第一次 Agent 列表：標了原因的訊息之後不會自己送出")
    func problemsAreNotRetried() async {
        let deliveries = Deliveries()
        let queue = Self.queue(deliveries: deliveries)
        queue.enqueue(Self.prompt())

        await queue.reconcile(with: Self.snapshot(session: "s-2"))
        await queue.reconcile(with: Self.snapshot())

        #expect(deliveries.sent.isEmpty)
        #expect(queue.entries.first?.problem == .conversationChanged)
    }

    @Test("每台主機最多 30 則：第 31 則不收")
    func limitIsThirtyPerHost() {
        let store = InMemoryOfflineQueueStore()
        let queue = Self.queue(store: store)
        for index in 1...30 { #expect(queue.enqueue(Self.prompt("第 \(index) 則"))) }

        #expect(queue.isFull)
        #expect(!queue.enqueue(Self.prompt("第 31 則")))
        #expect(queue.entries.count == 30)
        // 別台主機另算。
        let other = OfflineQueue(host: "other", store: store, deliver: Deliveries().deliver)
        #expect(other.enqueue(Self.prompt("別台")))
    }

    @Test("補送沒送到：需要你、被拒、無法確認各自標原因，同一個 pane 後面的也不送")
    func deliveryProblemsStopThatPane() async {
        let deliveries = Deliveries()
        deliveries.outcome = .needsAnswer
        let queue = Self.queue(deliveries: deliveries)
        queue.enqueue(Self.prompt("第一則"))
        queue.enqueue(Self.prompt("第二則"))

        await queue.reconcile(with: Self.snapshot(status: .blocked))

        #expect(deliveries.sent.map(\.text) == ["第一則"])
        #expect(queue.entries.map(\.problem) == [.needsAnswer, .needsAnswer])

        for (outcome, problem) in [(PromptOutcome.rejected(message: "no"), QueuedPrompt.Problem.notDelivered),
                                   (.unconfirmed(.connectionLost), .mayHaveBeenSent), (.noResponse, .mayHaveBeenSent),
                                   // 主機送出前比對發現對話已變更(#304 的 pane_changed):什麼都沒送出，標成對話已變更。
                                   (.paneChanged, .conversationChanged)] {
            let deliveries = Deliveries()
            deliveries.outcome = outcome
            let queue = Self.queue(deliveries: deliveries)
            queue.enqueue(Self.prompt())
            await queue.reconcile(with: Self.snapshot())
            #expect(queue.entries.first?.problem == problem)
        }
    }

    @Test("存在本機：App 重開(新的佇列讀同一個 store)仍在")
    func persistsAcrossLaunches() {
        let blobs = ProtectedOfflineQueueStoreTests.MemoryBlobs()
        let legacy = ProtectedOfflineQueueStoreTests.initializedLegacy()
        let firstStore = ProtectedOfflineQueueStore(blobs: blobs, legacy: legacy)
        let first = Self.queue(store: firstStore)
        first.enqueue(Self.prompt("重開也在"))
        firstStore.flush()

        let relaunched = Self.queue(store: ProtectedOfflineQueueStore(blobs: blobs, legacy: legacy))

        #expect(relaunched.entries.map(\.text) == ["重開也在"])
        #expect(relaunched.entries.first?.sessionID == "s-1")
        #expect(relaunched.entries.first?.workspaceID == "w1")
        #expect(relaunched.entries.first?.createdAt == Self.start)
    }

    @Test("取消、放回輸入框：從佇列拿掉，放回時拿到原文")
    func cancelAndTakeBack() async {
        let deliveries = Deliveries()
        let queue = Self.queue(deliveries: deliveries)
        queue.enqueue(Self.prompt("取消我"))
        queue.enqueue(Self.prompt("放回我"))
        let cancelled = queue.entries[0].id
        let restored = queue.entries[1].id

        queue.remove(cancelled)
        #expect(queue.takeBack(restored) == "放回我")
        await queue.reconcile(with: Self.snapshot())

        #expect(queue.entries.isEmpty)
        #expect(deliveries.sent.isEmpty)
    }

    @Test("收到 Agent 列表：有排隊中的才比對;同時只跑一次")
    func receiveReconcilesOnce() async {
        let deliveries = Deliveries()
        let queue = Self.queue(deliveries: deliveries)
        queue.enqueue(Self.prompt())

        queue.receive(Self.snapshot())
        queue.receive(Self.snapshot())
        await queue.waitUntilIdle()

        #expect(deliveries.sent.count == 1)
        #expect(queue.entries.isEmpty)
    }

    // MARK: - 送出管線的步驟

    @Test("步驟：連得上直接通過;離線排進佇列、輸入框維持清空;滿了文字放回輸入框")
    func stepQueuesWhenOffline() async {
        let queue = Self.queue()
        let step = OfflineQueueStep(queue: queue)
        let online = SendPipelineClock(now: { Self.start })
        let offline = SendPipelineClock(now: { Self.start }, isHostReachable: { false })
        let prompt = OutgoingPrompt(text: "連得上", paneID: "w1:p6", expectedSession: "s-1", createdAt: Self.start)

        #expect(await step.process(prompt, clock: online) == .proceed(prompt))
        #expect(queue.entries.isEmpty)
        #expect(await step.process(Self.prompt("離線"), clock: offline) == .halt(SendHalt(restoresDraft: false)))
        #expect(queue.entries.map(\.text) == ["離線"])
        for _ in 2...OfflineQueue.limit { queue.enqueue(Self.prompt()) }
        #expect(await step.process(Self.prompt("滿了"), clock: offline) == .halt(SendHalt(restoresDraft: true)))
        #expect(queue.entries.count == 30)
    }

    // MARK: - 聊天輸入列

    static func openedWithQueue(_ queue: OfflineQueue) async throws -> ConversationSendTests.Setup {
        try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts, sendSteps: [OfflineQueueStep(queue: queue)], sleep: RecordingSleeper().sleep)
        }
    }

    /// 連續兩次讀不到快照(第一次靜默重試)才算離線。
    static func goOffline(_ setup: ConversationSendTests.Setup) async {
        for _ in 0..<2 {
            await setup.host.bridge.expect(ConversationSendTests.bridge, reply: FakeReply(exitCode: 255))
        }
        await setup.model.poll()
    }

    @Test("聊天：離線時仍可送出，訊息排進佇列(對話最下面)、什麼都沒送、輸入框清空")
    func offlineSendQueues() async throws {
        let queue = Self.queue()
        let setup = try await Self.openedWithQueue(queue)
        await Self.goOffline(setup)
        #expect(setup.model.isOffline)
        setup.model.draft = "連上再送"

        #expect(setup.model.canSend)
        await setup.model.send()

        #expect(setup.model.draft == "")
        #expect(setup.model.echoes.isEmpty)
        #expect(await ConversationSendTests.promptRequests(setup).isEmpty)
        #expect(setup.model.queuedPrompts.map(\.text) == ["連上再送"])
        #expect(queue.entries.first?.sessionID == ConversationModelTests.sessionID)
        #expect(queue.entries.first?.workspaceID == "w1")
    }

    @Test("聊天：倒數期間斷線，倒數結束時才判斷:排進佇列、不送主機;倒數期間恢復連線則照送")
    func reachabilityIsDecidedWhenCountdownEnds() async throws {
        let queue = Self.queue()
        let countdown = UndoSendCountdown(seconds: { 5 })
        let setup = try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts, sendSteps: [countdown, OfflineQueueStep(queue: queue)],
                sleep: RecordingSleeper().sleep)
        }
        setup.model.draft = "倒數中斷線"
        let sending = Task { await setup.model.send() }
        await UndoSendTests.until { countdown.pending != nil }
        #expect(!setup.model.isOffline)

        await Self.goOffline(setup)
        countdown.sendNow()
        await sending.value

        #expect(setup.model.queuedPrompts.map(\.text) == ["倒數中斷線"])
        #expect(await ConversationSendTests.promptRequests(setup).isEmpty)
    }

    @Test("聊天：重連後讀到的 Agent 列表交給佇列補送")
    func reconnectedPollDeliversQueue() async throws {
        let deliveries = Deliveries()
        let queue = Self.queue(deliveries: deliveries)
        let setup = try await Self.openedWithQueue(queue)
        await Self.goOffline(setup)
        setup.model.draft = "連上再送"
        await setup.model.send()

        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.model.poll()
        await queue.waitUntilIdle()

        #expect(deliveries.sent.map(\.text) == ["連上再送"])
        #expect(setup.model.queuedPrompts.isEmpty)
    }

    @Test("聊天：沒送出的訊息放回輸入框或刪除")
    func putBackAndDeleteQueued() async throws {
        let queue = Self.queue()
        let setup = try await Self.openedWithQueue(queue)
        await Self.goOffline(setup)
        setup.model.draft = "放回來"
        await setup.model.send()
        setup.model.draft = "刪掉"
        await setup.model.send()
        let entries = setup.model.queuedPrompts

        setup.model.putBack(entries[0].id)
        setup.model.deleteQueued(entries[1].id)

        #expect(setup.model.draft == "放回來")
        #expect(setup.model.queuedPrompts.isEmpty)
    }

    @Test("聊天：沒有離線佇列時，離線不能送出")
    func offlineWithoutQueueCannotSend() async throws {
        let setup = try await ConversationSendTests.opened()
        await Self.goOffline(setup)
        setup.model.draft = "送不出去"

        #expect(!setup.model.canSend)
    }

    // MARK: - 主機

    @Test("主機：主機更新來源讀到 Agent 列表就交給那台主機的離線佇列，補送前再讀一次新鮮的快照")
    func hostUpdatesDeliverQueue() async {
        let demo = FakeHost()
        let bridge = HerdrCommand.bridge()
        await demo.expect(bridge, reply: .recorded("session.snapshot.ndjson"))
        await demo.expect(bridge, reply: .recorded("session.snapshot.ndjson"))
        await demo.expect(bridge, reply: ConversationSendTests.delivered)
        let model = HostsModel(
            store: MemoryHostStore(), demoChannel: demo, offlineQueues: InMemoryOfflineQueueStore(), makeChannel: ChannelFactory().make)
        model.load()
        let queue = model.offlineQueue(for: .demo)
        queue.enqueue(OutgoingPrompt(
            text: "重連後補送", paneID: ConversationModelTests.paneID, expectedSession: ConversationModelTests.sessionID,
            createdAt: Date(), workspaceID: "w1"))

        await model.agentList.load()
        await queue.waitUntilIdle()

        #expect(queue.entries.isEmpty)
        let prompts = await demo.executions.map(\.stdinText).filter { $0.contains(#""method":"agent.prompt""#) }
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("重連後補送") == true)
    }

    @Test("主機：補送前重讀的新鮮快照 session 已換，不送、標成對話已變更")
    func freshSnapshotWithDifferentSessionIsNotDelivered() async {
        let demo = FakeHost()
        let bridge = HerdrCommand.bridge()
        await demo.expect(bridge, reply: .recorded("session.snapshot.ndjson"))
        await demo.expect(bridge, reply: ConversationModelTests.snapshot { $0["agent_session"] = ["source": "herdr:claude", "agent": "claude", "kind": "id", "value": "other-session"] })
        let model = HostsModel(
            store: MemoryHostStore(), demoChannel: demo, offlineQueues: InMemoryOfflineQueueStore(), makeChannel: ChannelFactory().make)
        model.load()
        let queue = model.offlineQueue(for: .demo)
        queue.enqueue(OutgoingPrompt(
            text: "不能送到別的對話", paneID: ConversationModelTests.paneID, expectedSession: ConversationModelTests.sessionID,
            createdAt: Date(), workspaceID: "w1"))

        await model.agentList.load()
        await queue.waitUntilIdle()

        #expect(queue.entries.first?.problem == .conversationChanged)
        let prompts = await demo.executions.map(\.stdinText).filter { $0.contains(#""method":"agent.prompt""#) }
        #expect(prompts.isEmpty)
    }

    @Test("主機：同一台主機的聊天共用一份佇列")
    func conversationsShareHostQueue() {
        let model = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        model.load()
        let chat = model.conversation(ChatRoute(host: .demo, paneID: "w1:p1"), sessionID: nil)

        #expect(chat.offlineQueue === model.offlineQueue(for: .demo))
    }
}
