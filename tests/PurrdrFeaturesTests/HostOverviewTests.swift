import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機 tab 的單台主機總頁(#392):狀態、各區塊要不要出現。
@MainActor
@Suite("主機 tab 總頁")
struct HostOverviewTests {
    static let studio = HostConfiguration(
        name: "Studio", endpoint: SSHEndpoint(host: "studio-mac", username: "demo"),
        herdr: HerdrInstallation(session: "work"), operatingSystem: .macOS, hostKeyPin: HostsModelTests.pin)
    static let buildBox = HostConfiguration(name: "Build Box", hostService: HostServiceAddress("buildbox.tail1234.ts.net")!)

    static func sshModel(loading: Bool = true) async -> HostsModel {
        let store = MemoryHostStore()
        store.hosts = [studio]
        let real = FakeHost()
        if loading { await real.expect(HerdrCommand.bridge(HerdrInstallation(session: "work")), reply: .recorded("session.snapshot.ndjson")) }
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(real).make)
        model.load()
        return model
    }

    static func httpsModel(
        paired: Bool = true, connection: FakeHostConnection = FakeHostConnection()
    ) -> HostsModel {
        let store = MemoryHostStore()
        store.hosts = [buildBox]
        let connections = HostServiceConnections()
        connections.connections = [connection]
        let tokens = InMemoryDeviceTokenStore(tokens: paired ? [buildBox.id: "token"] : [:])
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), hostService: connections.access(tokens: tokens), makeChannel: ChannelFactory().make)
        model.load()
        return model
    }

    @Test("沒有任何主機也沒有範例主機時沒有總頁")
    func noHostHasNoOverview() {
        let model = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        model.demoEntered = false
        model.load()
        #expect(model.overview == nil)
    }

    @Test("範例主機:只有範例狀態與模擬登入 Shell(App Review 用,#434),沒有用量、分享與主機服務")
    func demoHost() {
        let model = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        model.load()
        let overview = model.overview
        #expect(overview?.status == .demo)
        #expect(overview?.showsUsage == false)
        #expect(overview?.showsLoginShell == true)
        #expect(overview?.canShare == false)
        #expect(overview?.showsHostService == false)
        #expect(overview?.isSaved == false)
    }

    @Test("SSH 主機讀到快照:線上,帶 herdr 版本,有用量與登入 Shell,沒有主機服務")
    func onlineSSHHost() async {
        let model = await Self.sshModel()
        await model.agentList.load()
        let overview = model.overview
        #expect(overview?.status == .online)
        #expect(overview?.herdrVersion == "0.9.5")
        #expect(overview?.connection == .tailscaleSSH)
        #expect(overview?.showsUsage == true)
        #expect(overview?.showsLoginShell == true)
        #expect(overview?.showsHostService == false)
        #expect(overview?.canShare == true)
        #expect(overview?.hasHostSettings == true)
        #expect(overview?.isSaved == true)
    }

    @Test("連線進行中:連線中")
    func connecting() async {
        let model = await Self.sshModel()
        #expect(model.overview?.status == .connecting)
    }

    @Test("讀不到快照:離線,帶原因;保留最後連線時間")
    func offline() async {
        let model = await Self.sshModel(loading: false)
        await model.agentList.load()
        guard case .offline(let message, let last)? = model.overview?.status else {
            Issue.record("預期離線,實際是 \(String(describing: model.overview?.status))")
            return
        }
        #expect(!message.isEmpty)
        #expect(last == nil)
        #expect(model.overview?.showsLoginShell == true)
    }

    @Test("這支裝置還沒配對的 HTTPS 主機:要配對,不顯示用量、主機服務與登入 Shell")
    func unpairedHTTPS() {
        let model = Self.httpsModel(paired: false)
        let overview = model.overview
        #expect(overview?.status == .needsPairing)
        #expect(overview?.showsUsage == false)
        #expect(overview?.showsHostService == false)
        #expect(overview?.showsLoginShell == false)
        #expect(overview?.canShare == true)
    }

    @Test("已配對的 HTTPS 主機:有主機服務區塊,沒有登入 Shell;用量區留著(主機服務 0.12.0 起支援)")
    func pairedHTTPS() async {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        let model = Self.httpsModel(connection: connection)
        await model.agentList.load()
        let overview = model.overview
        #expect(overview?.status == .online)
        #expect(overview?.connection == .https)
        #expect(overview?.address == Self.buildBox.hostService?.description)
        #expect(overview?.address?.contains("buildbox.tail1234.ts.net") == true)
        #expect(overview?.showsHostService == true)
        #expect(overview?.showsLoginShell == false)
        #expect(overview?.showsUsage == true)
    }

    @Test("唯讀裝置配對的 HTTPS 主機:線上·唯讀")
    func readOnlyHTTPS() async {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await connection.setReadOnlyDevice(true)
        let model = Self.httpsModel(connection: connection)
        await model.agentList.load()
        await model.refreshOverviewFacts()
        #expect(model.overview?.status == .readOnly)
    }

    @Test("herdr 低於 0.9.5:太舊,不顯示用量")
    func herdrTooOld() async {
        let connection = FakeHostConnection()
        let old = Fixtures.modifiedLine("session.snapshot.ndjson") { line in
            var result = line["result"] as? [String: Any] ?? [:]
            var snapshot = result["snapshot"] as? [String: Any] ?? [:]
            snapshot["version"] = "0.9.3"
            result["snapshot"] = snapshot
            line["result"] = result
        }
        await connection.expect("session.snapshot", reply: old)
        let model = Self.httpsModel(connection: connection)
        await model.agentList.load()
        #expect(model.overview?.status == .herdrTooOld(version: "0.9.3"))
        #expect(model.overview?.showsUsage == false)
    }
}
