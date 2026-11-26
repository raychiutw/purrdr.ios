import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 進背景保留連線(#551)在 model 層的行為:保留期內回前景不重撥;保留期間 model 沒有輪詢、沒有狀態寫入。
/// `BackgroundRetentionController` 本身的規則在 `BackgroundRetentionControllerTests`;這裡接上 `HostsModel` 與列表 model,
/// 用假主機與注入時間確認「保留」的實際效果(連線沒被丟、沒有新指令、沒有觀察到的狀態變化)。
private final class ObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

@MainActor
@Suite("進背景保留連線的 model 行為(#551)")
struct BackgroundRetentionModelTests {
    @MainActor
    private final class Scheduler: BackgroundTaskScheduling {
        private(set) var ended: [Int] = []
        var fire: (@MainActor () -> Void)?
        func begin(expiration: @escaping @MainActor () -> Void) -> Int? { 1 }
        func end(_ task: Int) { ended.append(task) }
        func remainingTime() -> TimeInterval { 30 }
        func schedule(after seconds: TimeInterval, fire: @escaping @MainActor () -> Void) -> () -> Void {
            self.fire = fire
            return {}
        }
    }

    @Test("保留期內(含保留上限那一刻)回前景:不丟棄連線、不重新建立通道、不預先撥號、不送任何指令")
    func returningWithinRetentionDoesNotRedial() async throws {
        let linux = FakeHost()
        let factory = ChannelFactory(linux)
        let store = MemoryHostStore()
        store.hosts = [HostManagementTests.linux]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: factory.make)
        model.load()
        let channelsBefore = factory.endpoints.count
        let scheduler = Scheduler()
        let controller = BackgroundRetentionController(scheduler: scheduler)
        let start = Date(timeIntervalSince1970: 5_000)

        controller.didEnterBackground(isDeviceLocked: false)
        model.sceneDidEnterBackground(at: start)
        #expect(controller.isRetaining)
        // 進背景當下與保留期間不得有任何非同步動作(例如丟連線):讓出幾輪確認。
        for _ in 0..<50 { await Task.yield() }
        #expect(await linux.disconnectCount == 0, "進背景當下就丟了連線")
        // 回前景的時刻取保留時間本身(剩餘 30 秒時是 25 秒):這一刻連線仍視為活著。
        let retention = BackgroundRetentionController.retentionSeconds(remaining: 30)
        await model.sceneDidBecomeActive(at: start.addingTimeInterval(retention))
        controller.didBecomeActive()

        #expect(await linux.disconnectCount == 0, "沒有丟棄連線")
        #expect(await linux.executions.isEmpty, "沒有預先撥號或探測")
        #expect(factory.endpoints.count == channelsBefore, "沒有重新建立通道")
        #expect(!controller.isRetaining)
        #expect(scheduler.ended == [1])
    }

    @Test("保留時間一過、連線被 iOS 關掉的情況:同一條路徑超過保留時間才重撥(對照組)")
    func returningAfterRetentionRedials() async throws {
        let linux = FakeHost()
        await linux.expect(WakeProbe.command, reply: FakeReply())
        let store = MemoryHostStore()
        store.hosts = [HostManagementTests.linux]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(linux).make)
        model.load()
        let start = Date(timeIntervalSince1970: 5_000)

        model.sceneDidEnterBackground(at: start)
        await model.sceneDidBecomeActive(at: start.addingTimeInterval(BackgroundRetention.duration + 1))

        #expect(await linux.disconnectCount == 1)
    }

    @Test("保留期間:進背景、保留中、保留結束都沒有新的主機指令、連線不斷、列表與徽章沒有任何狀態寫入")
    func nothingHappensDuringRetention() async throws {
        let host = FakeHost()
        await host.expect(HerdrCommand.bridge(), reply: .recorded("session.snapshot.ndjson"))
        // 第二份快照留著:保留期間若有人偷讀列表,它就會被用掉(下面確認沒被用到)。
        await host.expect(HerdrCommand.bridge(), reply: .recorded("session.snapshot.ndjson") { response in
            SnapshotEdit.agent("w1:pA", in: &response) { $0["agent_status"] = "blocked" }
        })
        let model = HostsModel(store: MemoryHostStore(), demoChannel: host, makeChannel: { _, _, _ in FakeHost() })
        model.load()
        await model.agentList.load()
        let executionsBefore = await host.executions.count
        let rowsBefore = model.agentList.sections.flatMap(\.rows).map(\.id)
        let badge = NeedsYouBadge(merged: model.agentList)
        badge.start()

        let observed = ObservedFlag()
        withObservationTracking {
            _ = (model.agentList.sections, model.agentList.needsYouCount(), badge.count)
        } onChange: {
            observed.raise()
        }
        let scheduler = Scheduler()
        let controller = BackgroundRetentionController(scheduler: scheduler)
        // 進背景(畫面層的 `.task` 會停掉列表的輪詢;保留的只有連線本身),保留期間經過,再讓保留時間到。
        controller.didEnterBackground(isDeviceLocked: false)
        model.sceneDidEnterBackground(at: Date(timeIntervalSince1970: 7_000))
        for _ in 0..<50 { await Task.yield() }
        #expect(controller.isRetaining)
        scheduler.fire?()
        for _ in 0..<50 { await Task.yield() }

        #expect(await host.executions.count == executionsBefore, "沒有輪詢或重撥")
        #expect(await host.unmetExpectations.count == 1, "保留期間有人讀了列表")
        #expect(await host.disconnectCount == 0, "保留期間不丟連線")
        #expect(model.agentList.sections.flatMap(\.rows).map(\.id) == rowsBefore)
        #expect(!observed.isRaised, "沒有任何狀態寫入")
        #expect(!controller.isRetaining)
    }
}
