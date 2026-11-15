import Foundation
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
        await host.expect(Self.bridge, reply: FakeReply(exitCode: 255))  // 退避後重讀也失敗
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

        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await host.expect(Self.bridge, reply: .recorded("events.subscribe.started.ndjson", keepsOpen: true))
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        model.retryNow()

        try await waitUntil { await host.consumedAll(executions: 6) }
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

        model.networkPathChanged("satisfied:wifi")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await linux.disconnectCount == 0, "第一次回報不該重設")

        model.networkPathChanged("satisfied:wifi")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await linux.disconnectCount == 0, "路徑沒變不該重設")

        model.networkPathChanged("satisfied:cellular")
        try await waitUntil { await linux.disconnectCount == 1 }
        try await waitUntil { await studio.disconnectCount == 1 }
    }

    @Test("背景超過 60 秒回前景：對已連過的主機跑喚醒探測(true)")
    func longBackgroundRunsWakeProbe() async throws {
        let linux = FakeHost()
        await linux.expect(WakeProbe.command, reply: FakeReply())
        let model = Self.hostsModel(linux)
        model.load()
        let start = Date(timeIntervalSince1970: 1_000)

        model.sceneDidEnterBackground(at: start)
        await model.sceneDidBecomeActive(at: start.addingTimeInterval(61))

        #expect(await linux.executions.map(\.command) == ["true"])
        #expect(await linux.disconnectCount == 0)
    }

    @Test("背景不到 60 秒回前景：不探測")
    func shortBackgroundSkipsProbe() async {
        let linux = FakeHost()
        let model = Self.hostsModel(linux)
        model.load()
        let start = Date(timeIntervalSince1970: 1_000)

        model.sceneDidEnterBackground(at: start)
        await model.sceneDidBecomeActive(at: start.addingTimeInterval(30))
        await model.sceneDidBecomeActive(at: start.addingTimeInterval(300))

        #expect(await linux.executions.isEmpty)
    }
}

extension ChannelFactory {
    convenience init(_ hosts: [FakeHost]) {
        self.init()
        self.hosts = hosts
    }
}
