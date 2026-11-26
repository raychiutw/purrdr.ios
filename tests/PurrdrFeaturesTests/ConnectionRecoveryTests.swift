import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 連線韌性(#10、行為規格 §7.3–7.5):網路切換、回到前景、中斷後重試。
@MainActor
@Suite("連線韌性")
struct ConnectionRecoveryTests {
    static let bridge = HerdrCommand.bridge()

    @Test("連線中斷：列表保留最後的列並標示原因;按重試立刻重連，不等退避")
    func retryNowSkipsBackoff() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await host.expect(Self.bridge, reply: FakeReply(exitCode: 255))  // 訂閱在 ack 前就斷了
        await host.expect(Self.bridge, reply: FakeReply(exitCode: 255))  // 退避後重新訂閱也失敗(手上有快照，不先讀)
        let sleeper = Sleeper(blockAfter: 2)
        let model = AgentListModel(client: HerdrClient(channel: host), sleep: sleeper.sleep)
        let task = Task { await model.run() }
        defer { task.cancel() }
        try await waitUntil { await sleeper.durations.count == 2 }
        guard case .failed = model.phase else {
            Issue.record("中斷時沒有標示:\(model.phase)")
            return
        }
        #expect(model.sections.flatMap(\.rows).count == 3, "中斷時列表被清空")

        await host.expect(Self.bridge, reply: .recorded("events.subscribe.started.ndjson", keepsOpen: true))
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        model.retryNow()

        try await waitUntil { await host.consumedAll(executions: 5) }
        try await waitUntil { await MainActor.run { model.phase == .loaded } }
        #expect(await sleeper.durations.count == 2)
    }

    @Test("沒在退避時按重試：下一次退避直接跳過(不會漏掉)")
    func retryRequestedDuringAttemptIsKept() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: FakeReply(exitCode: 255))
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await host.expect(Self.bridge, reply: .recorded("events.subscribe.started.ndjson", keepsOpen: true))
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        let sleeper = Sleeper(blockAfter: 1)
        let model = AgentListModel(client: HerdrClient(channel: host), sleep: sleeper.sleep)

        model.retryNow()
        let task = Task { await model.run() }
        defer { task.cancel() }

        try await waitUntil { await host.consumedAll(executions: 4) }
    }

    static func hostsModel(_ channels: FakeHost...) -> HostsModel {
        let store = MemoryHostStore()
        store.hosts = [HostManagementTests.studio, HostManagementTests.linux]
        return HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(channels).make)
    }

    @Test("網路路徑改變(Wi-Fi↔行動網路、Tailscale 上下線):丟棄所有主機的連線，下一個指令在新路由上撥號;第一次回報只記錄")
    func networkChangeDropsConnections() async throws {
        let linux = FakeHost()
        let studio = FakeHost()
        let model = Self.hostsModel(linux, studio)
        model.load()
        model.select(.host(HostManagementTests.studio.id))

        // 不用固定等待：等重設的 task 跑完(沒有重設就沒有 task)再看連線。
        await model.networkPathChanged("satisfied:wifi")?.value
        #expect(await linux.disconnectCount == 0, "第一次回報不該重設")

        await model.networkPathChanged("satisfied:wifi")?.value
        #expect(await linux.disconnectCount == 0, "路徑沒變不該重設")

        await model.networkPathChanged("satisfied:cellular")?.value
        #expect(await linux.disconnectCount == 1)
        #expect(await studio.disconnectCount == 1)
    }

    /// #133:實機斷線時，從 Console 看得出是不是網路切換丟掉了連線。
    @Test("網路路徑改變而丟棄連線時留下診斷紀錄(舊路徑 → 新路徑);第一次回報與沒變不記")
    func networkChangeIsLogged() async throws {
        let log = RecordingDiagnosticLog()
        let store = MemoryHostStore()
        store.hosts = [HostManagementTests.linux]
        let model = HostsModel(store: store, demoChannel: FakeHost(), diagnostics: log.log, makeChannel: ChannelFactory([FakeHost()]).make)
        model.load()

        await model.networkPathChanged("satisfied|wifi")?.value
        await model.networkPathChanged("satisfied|wifi")?.value
        #expect(log.messages.isEmpty)

        await model.networkPathChanged("satisfied|cellular,other")?.value
        #expect(log.messages.count == 1)
        #expect(log.messages.first?.contains("satisfied|wifi → satisfied|cellular,other") == true, "\(log.messages)")
    }

    @Test("網路路徑沒有連線時列表立刻知道裝置離線(第一次回報也算);恢復後回到有網路(#221)")
    func networkPathSetsListOffline() async throws {
        let store = MemoryHostStore()
        store.hosts = [HostManagementTests.linux]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory([FakeHost()]).make)
        model.load()

        await model.networkPathChanged("unsatisfied|")?.value
        #expect(model.agentList.isNetworkAvailable == false)

        await model.networkPathChanged("satisfied|wifi")?.value
        #expect(model.agentList.isNetworkAvailable == true)
    }

    @Test("背景超過保留時間回前景:不跑喚醒探測,直接丟棄連線重撥,並記「背景 N 秒，重撥」")
    func longBackgroundRedialsWithoutProbe() async throws {
        let log = RecordingDiagnosticLog()
        let linux = FakeHost()
        let store = MemoryHostStore()
        store.hosts = [HostManagementTests.linux]
        let model = HostsModel(store: store, demoChannel: FakeHost(), diagnostics: log.log, makeChannel: ChannelFactory([linux]).make)
        model.load()
        let start = Date(timeIntervalSince1970: 1_000)

        model.sceneDidEnterBackground(at: start)
        await model.sceneDidBecomeActive(at: start.addingTimeInterval(26))

        #expect(await linux.disconnectCount == 1, "直接丟棄,不是探測失敗才丟棄")
        #expect(log.messages == ["背景 26 秒，重撥"], "\(log.messages)")
    }

    @Test("背景超過保留時間回前景:丟棄後立刻預先撥號(在新連線上跑一個無害指令),撥號失敗不再丟一次連線")
    func redialPreconnects() async throws {
        let linux = FakeHost()
        await linux.expect(WakeProbe.command, reply: FakeReply())
        let model = Self.hostsModel(linux)
        model.load()
        let start = Date(timeIntervalSince1970: 1_000)

        model.sceneDidEnterBackground(at: start)
        await model.sceneDidBecomeActive(at: start.addingTimeInterval(61))

        #expect(await linux.executions.map(\.command) == ["true"])
        #expect(await linux.disconnectCount == 1)
    }

    @Test("背景沒超過保留時間回前景:沿用連線,不探測、不重撥、不預先撥號,並記「背景 N 秒，沿用」")
    func shortBackgroundReusesConnection() async {
        let log = RecordingDiagnosticLog()
        let linux = FakeHost()
        let store = MemoryHostStore()
        store.hosts = [HostManagementTests.linux]
        let model = HostsModel(store: store, demoChannel: FakeHost(), diagnostics: log.log, makeChannel: ChannelFactory([linux]).make)
        model.load()
        let start = Date(timeIntervalSince1970: 1_000)

        model.sceneDidEnterBackground(at: start)
        await model.sceneDidBecomeActive(at: start.addingTimeInterval(25))
        await model.sceneDidBecomeActive(at: start.addingTimeInterval(300))

        #expect(await linux.executions.isEmpty)
        #expect(await linux.disconnectCount == 0)
        #expect(log.messages == ["背景 25 秒，沿用"], "\(log.messages)")
    }

    @Test("重撥時列表先留著最後的快照,「連線中」前 1.5 秒不顯示,之後才顯示")
    func redialKeepsListAndHidesConnectingBriefly() async throws {
        let clock = AgentListLoadingTests.Clock()
        let connection = await AgentListLoadingTests.healthy()
        let model = MergedAgentListModel()
        model.update(
            sources: [AgentListLoadingTests.source(AgentListLoadingTests.lab, name: "Lab", connection: connection, clock: clock)],
            selected: AgentListLoadingTests.lab)
        await model.load()
        let rows = model.sections.flatMap(\.rows).count
        #expect(rows > 0)

        model.reconnectAfterForeground()

        #expect(model.sections.flatMap(\.rows).count == rows, "沿用最後的快照")
        #expect(model.hostStatuses(at: clock.now).isEmpty)
        clock.advance(seconds: 1.4)
        #expect(model.hostStatuses(at: clock.now).isEmpty)
        clock.advance(seconds: 0.1)
        #expect(model.hostStatuses(at: clock.now).map(\.state) == [.connecting])
        clock.advance(seconds: 8.5)
        #expect(model.hostStatuses(at: clock.now).map(\.state) == [.stillConnecting])
    }

    @Test("一般連線中(沒有快取):照舊立刻顯示連線中")
    func firstLoadStillShowsConnectingImmediately() async throws {
        let clock = AgentListLoadingTests.Clock()
        let model = MergedAgentListModel()
        model.update(
            sources: [AgentListLoadingTests.source(AgentListLoadingTests.lab, name: "Lab", connection: await AgentListLoadingTests.hanging(), clock: clock)],
            selected: AgentListLoadingTests.lab)
        let loading = Task { await model.load() }
        defer { loading.cancel() }

        model.reconnectAfterForeground()

        #expect(model.hostStatuses(at: clock.now).map(\.state) == [.connecting], "沒有快取可看,安靜重連不適用")
    }
}

extension ChannelFactory {
    convenience init(_ hosts: [FakeHost]) {
        self.init()
        self.hosts = hosts
    }
}
