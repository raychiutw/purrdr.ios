import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Send When Done(#305,spec #298):輸入列的「做完再送」開關開著時，送出改排進主機上的佇列，Agent 做完後依序送出。
@MainActor
@Suite("Send When Done")
struct SendWhenDoneTests {
    static let paneID = "w1:p1"

    static func item(_ id: String, _ text: String = "跑測試", session: String = "s-1") -> SendWhenDoneItem {
        SendWhenDoneItem(id: id, text: text, expectedSession: session)
    }

    static func prompt(_ text: String = "接著整理 commit", session: String? = "s-1") -> OutgoingPrompt {
        OutgoingPrompt(text: text, paneID: paneID, expectedSession: session, createdAt: SendPipelineTests.start)
    }

    static func clock() -> SendPipelineClock {
        SendPipelineClock(now: { SendPipelineTests.start }, sleep: { _ in })
    }

    /// 開始 `run()` 並等它讀完第一次佇列。
    static func running(_ model: SendWhenDoneModel, host: FakeSendWhenDoneHost) async -> Task<Void, Never> {
        let task = Task { await model.run() }
        await waitUntil { await host.calls.contains(.queues) && model.hasLoaded }
        return task
    }

    static func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<20_000 {
            if await condition() { return }
            await Task.yield()
        }
    }

    @Test("讀到自己這個 pane 的佇列與暫停原因，別的 pane 不顯示")
    func loadsOwnPaneQueue() async {
        let host = FakeSendWhenDoneHost(queues: [
            SendWhenDoneQueue(paneID: Self.paneID, items: [Self.item("q1"), Self.item("q2", "再來一則")], pause: .sessionChanged),
            SendWhenDoneQueue(paneID: "w2:p1", items: [Self.item("q9")]),
        ])
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }

        #expect(model.items == [Self.item("q1"), Self.item("q2", "再來一則")])
        #expect(model.pause == .sessionChanged)
        #expect(model.availability == .available)
    }

    @Test("調整順序:往前移動一格,送出重排請求、畫面換成新順序")
    func movesItemUp() async {
        let host = FakeSendWhenDoneHost(queues: [SendWhenDoneQueue(paneID: Self.paneID, items: [Self.item("q1"), Self.item("q2"), Self.item("q3")])])
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }

        await model.move("q3", by: -1)

        #expect(model.items.map(\.id) == ["q1", "q3", "q2"])
        #expect(await host.calls.contains(.reorder(paneID: Self.paneID, itemIDs: ["q1", "q3", "q2"])))
        #expect(model.notice == nil)
    }

    @Test("調整順序:頭尾不能再移出去,不送請求")
    func cannotMovePastEnds() async {
        let host = FakeSendWhenDoneHost(queues: [SendWhenDoneQueue(paneID: Self.paneID, items: [Self.item("q1"), Self.item("q2")])])
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }

        #expect(!model.canMove("q1", by: -1))
        #expect(model.canMove("q1", by: 1))
        #expect(!model.canMove("q2", by: 1))
        await model.move("q1", by: -1)

        #expect(model.items.map(\.id) == ["q1", "q2"])
        #expect(await !host.calls.contains { if case .reorder = $0 { true } else { false } })
    }

    @Test("調整順序:主機拒絕時換回原本的順序並說明")
    func moveFailureRestoresOrder() async {
        let host = FakeSendWhenDoneHost(queues: [SendWhenDoneQueue(paneID: Self.paneID, items: [Self.item("q1"), Self.item("q2")])])
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }
        await host.setFailure(HostServiceError.unreachable)

        await model.move("q2", by: -1)

        #expect(model.items.map(\.id) == ["q1", "q2"])
        #expect(model.notice != nil)
    }

    @Test("主機推 queue.changed:更新自己的佇列，別的 pane 的變動略過")
    func appliesPushedChanges() async {
        let host = FakeSendWhenDoneHost(queues: [SendWhenDoneQueue(paneID: Self.paneID, items: [Self.item("q1"), Self.item("q2")])])
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }

        await host.push(SendWhenDoneChange(queue: SendWhenDoneQueue(paneID: "w2:p1", items: [Self.item("q7")])))
        await host.push(SendWhenDoneChange(queue: SendWhenDoneQueue(paneID: Self.paneID, items: [Self.item("q2")]), sentItemID: "q1"))
        await Self.waitUntil { model.items.count == 1 }

        #expect(model.items == [Self.item("q2")])
        #expect(model.pause == nil)
    }

    @Test("連線斷了:退避後重開變動串流並重新讀佇列")
    func reconnectsAfterDrop() async {
        let host = FakeSendWhenDoneHost(queues: [SendWhenDoneQueue(paneID: Self.paneID, items: [Self.item("q1")])])
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }

        await host.dropConnection()
        await Self.waitUntil {
            let opened = await host.changeStreamsOpened
            let reads = await host.calls.filter { $0 == .queues }.count
            return opened == 2 && reads == 2
        }

        #expect(await host.changeStreamsOpened == 2)
        #expect(await host.calls.filter { $0 == .queues }.count == 2)
    }

    @Test("SSH 主機(沒有主機服務):停用，點開關只說明、不會開啟")
    func sshHostIsUnavailable() async {
        let model = SendWhenDoneModel(host: nil, paneID: Self.paneID, sleep: { _ in })
        await model.run()

        #expect(model.availability == .needsHostService)
        #expect(!model.isEnabled)
        model.toggle()
        #expect(!model.isEnabled)
    }

    @Test("唯讀裝置:停用並說明")
    func readOnlyDeviceIsUnavailable() async {
        let host = FakeSendWhenDoneHost(availability: .readOnlyDevice)
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        await model.run()

        #expect(model.availability == .readOnlyDevice)
        model.toggle()
        #expect(!model.isEnabled)
        #expect(await host.calls.isEmpty)
    }

    @Test("開關可用時切換開啟與關閉")
    func toggleSwitchesWhenAvailable() async {
        let host = FakeSendWhenDoneHost()
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }

        model.toggle()
        #expect(model.isEnabled)
        model.toggle()
        #expect(!model.isEnabled)
    }

    @Test("管線步驟:開著時送出排進佇列(帶 pane 與 expected_session)，輸入框維持清空")
    func stepQueuesWhenEnabled() async {
        let host = FakeSendWhenDoneHost()
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }
        model.toggle()

        let result = await SendWhenDoneStep(model: model).process(Self.prompt(), clock: Self.clock())

        #expect(result == .halt(SendHalt(restoresDraft: false)))
        #expect(await host.calls.contains(.add(paneID: Self.paneID, text: "接著整理 commit", expectedSession: "s-1")))
        await Self.waitUntil { model.items.count == 1 }
        #expect(model.items.map(\.text) == ["接著整理 commit"])
    }

    @Test("管線步驟:關著時原樣通過，不碰主機")
    func stepPassesThroughWhenDisabled() async {
        let host = FakeSendWhenDoneHost()
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }

        let result = await SendWhenDoneStep(model: model).process(Self.prompt(), clock: Self.clock())

        #expect(result == .proceed(Self.prompt()))
        #expect(await host.calls.allSatisfy { $0 == .queues })
    }

    @Test("管線步驟:佇列滿了，文字放回輸入框並說明")
    func stepRestoresDraftWhenQueueIsFull() async {
        let host = FakeSendWhenDoneHost()
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }
        model.toggle()
        await host.setFailure(HostServiceError.queueFull)

        let result = await SendWhenDoneStep(model: model).process(Self.prompt(), clock: Self.clock())

        #expect(result == .halt(SendHalt(restoresDraft: true)))
        #expect(model.notice == HostErrorText.message(for: HostServiceError.queueFull))
    }

    @Test("管線步驟:還不知道 session 時不能排(主機要比對)，文字放回輸入框")
    func stepRestoresDraftWithoutSession() async {
        let host = FakeSendWhenDoneHost()
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }
        model.toggle()

        let result = await SendWhenDoneStep(model: model).process(Self.prompt(session: nil), clock: Self.clock())

        #expect(result == .halt(SendHalt(restoresDraft: true)))
        #expect(model.notice != nil)
        #expect(await host.calls.allSatisfy { $0 == .queues })
    }

    @Test("刪除:送 queue.remove;已不在佇列也算刪掉並重讀")
    func removeDeletesAndToleratesUnknown() async {
        let host = FakeSendWhenDoneHost(queues: [SendWhenDoneQueue(paneID: Self.paneID, items: [Self.item("q1"), Self.item("q2")])])
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }

        await model.remove("q1")
        await Self.waitUntil { model.items.count == 1 }
        #expect(model.items.map(\.id) == ["q2"])

        await model.remove("q1")
        #expect(model.notice == nil)
    }

    @Test("編輯:從佇列拿掉並交回文字，放回輸入框")
    func takeBackRemovesAndReturnsText() async {
        let host = FakeSendWhenDoneHost(queues: [SendWhenDoneQueue(paneID: Self.paneID, items: [Self.item("q1", "改一下標題")])])
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }

        let text = await model.takeBack("q1")

        #expect(text == "改一下標題")
        #expect(await host.calls.contains(.remove(paneID: Self.paneID, itemID: "q1")))
    }

    @Test("編輯:刪除失敗(連線錯誤)時文字不丟，也不放回(仍在主機佇列)")
    func takeBackKeepsItemWhenRemoveFails() async {
        let host = FakeSendWhenDoneHost(queues: [SendWhenDoneQueue(paneID: Self.paneID, items: [Self.item("q1", "改一下標題")])])
        let model = SendWhenDoneModel(host: host, paneID: Self.paneID, sleep: { _ in })
        let task = await Self.running(model, host: host)
        defer { task.cancel() }
        await host.setFailure(HostServiceError.connectionLost)

        let text = await model.takeBack("q1")

        #expect(text == nil)
        #expect(model.items.map(\.id) == ["q1"])
        #expect(model.notice != nil)
    }
}
