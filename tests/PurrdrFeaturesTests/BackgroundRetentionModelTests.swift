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

    @Test("保留期間:列表停止驅動後沒有新的主機指令、連線不斷、觀察得到的狀態沒有任何寫入;保留結束也一樣")
    func nothingHappensDuringRetention() async throws {
        let bridge = HerdrCommand.bridge()
        let host = FakeHost()
        await host.expect(bridge, reply: .recorded("session.snapshot.ndjson"))
        await host.expect(bridge, reply: .recorded("events.subscribe.started.ndjson", keepsOpen: true))
        await host.expect(bridge, reply: .recorded("session.snapshot.ndjson"))
        let model = AgentListModel(client: HerdrClient(channel: host))
        let run = Task { await model.run() }
        try await waitUntil { await MainActor.run { model.phase == .loaded } }

        let scheduler = Scheduler()
        let controller = BackgroundRetentionController(scheduler: scheduler)
        // 進背景:畫面層的 `.task(id: scenePhase == .active)` 會取消 run;保留的只有連線本身。
        controller.didEnterBackground(isDeviceLocked: false)
        run.cancel()
        _ = await run.value
        let executionsBefore = await host.executions.count
        let rowsBefore = model.sections.flatMap(\.rows).map(\.id)

        let observed = ObservedFlag()
        withObservationTracking {
            _ = (model.phase, model.sections)
        } onChange: {
            observed.raise()
        }
        // 保留期間經過(沒有任何計時器被推進,等同什麼都沒發生),再讓保留時間到。
        for _ in 0..<50 { await Task.yield() }
        scheduler.fire?()

        #expect(await host.executions.count == executionsBefore, "沒有輪詢或重撥")
        #expect(await host.disconnectCount == 0, "保留期間不丟連線")
        #expect(model.sections.flatMap(\.rows).map(\.id) == rowsBefore)
        #expect(!observed.isRaised, "沒有任何狀態寫入")
        #expect(!controller.isRetaining)
    }
}
