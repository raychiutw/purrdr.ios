import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

@MainActor
@Suite("主機清單")
struct HostsModelTests {
    static let pin = HostKeyFingerprint(stored: "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww")!
    static let studio = HostConfiguration(
        name: "Studio", endpoint: SSHEndpoint(host: "ray-mac-mini", username: "demo"),
        herdr: HerdrInstallation(session: "work"), operatingSystem: .macOS, hostKeyPin: pin)

    @Test("沒有主機時選 Demo 主機，Agent 列表讀 Demo 的資料")
    func noHostsUsesDemo() async {
        let demo = FakeHost()
        await demo.expect(HerdrCommand.bridge(), reply: .recorded("session.snapshot.ndjson"))
        let model = HostsModel(store: MemoryHostStore(), demoChannel: demo, makeChannel: ChannelFactory().make)

        model.load()
        await model.agentList.load()

        #expect(model.selection == .demo)
        #expect(model.agentList.phase == .loaded)
        #expect(await demo.unmetExpectations.isEmpty)
    }

    @Test("有已存的主機時，Agent 列表經 SSH 讀那台主機(帶 pin、herdr session)")
    func savedHostDrivesAgentList() async throws {
        let store = MemoryHostStore()
        store.hosts = [Self.studio]
        let real = FakeHost()
        await real.expect(HerdrCommand.bridge(Self.studio.herdr), reply: .recorded("session.snapshot.ndjson"))
        let factory = ChannelFactory(real)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: factory.make)

        model.load()
        await model.agentList.load()

        #expect(model.selection == .host(Self.studio.id))
        #expect(factory.endpoints == [Self.studio.endpoint])
        #expect(factory.pins == [Self.pin])
        #expect(model.agentList.sections.flatMap(\.rows).count == 3)
    }

    @Test("主機清單依名稱排序，每列顯示名稱、user@host:port,設了具名 session 就附註(#37 故事 24)")
    func rowsShowEndpointAndSession() {
        let store = MemoryHostStore()
        var plain = Self.studio
        plain.id = UUID()
        plain.name = "Linux box"
        plain.endpoint = SSHEndpoint(host: "100.64.0.9", port: 2222, username: "ops")
        plain.herdr = HerdrInstallation()
        store.hosts = [Self.studio, plain]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost()).make)

        model.load()

        #expect(model.rows == [
            HostRow(id: plain.id, title: "Linux box", subtitle: "ops@100.64.0.9:2222", session: nil, isSelected: true),
            HostRow(id: Self.studio.id, title: "Studio", subtitle: "demo@ray-mac-mini:22", session: "work", isSelected: false),
        ])
    }

    @Test("新增主機儲存後出現在清單並成為選取中主機，列表改讀那台")
    func savedHostBecomesSelected() async {
        let store = MemoryHostStore()
        let real = FakeHost()
        let factory = ChannelFactory(real)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: factory.make)
        model.load()

        store.hosts = [Self.studio]
        model.didSave(Self.studio)

        #expect(model.selection == .host(Self.studio.id))
        #expect(model.rows.map(\.id) == [Self.studio.id])
        #expect(factory.pins == [Self.pin])
    }

    @Test("連不上選取中主機時，列表說明原因(白話),不是泛用的讀取失敗")
    func connectionFailureExplainedInAgentList() async {
        let store = MemoryHostStore()
        store.hosts = [Self.studio]
        let refused = FakeHost()
        await refused.failConnection(with: SSHConnectionError.timedOut)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(refused).make)

        model.load()
        await model.agentList.load()

        #expect(model.agentList.phase == .failed(
            "The host didn’t answer in time. Make sure it’s awake and both devices are on your tailnet."))
    }

    @Test("Claude 用量跟著選取中主機：Demo 用 Demo 的同意紀錄，真主機以主機 id 用另一份同意紀錄")
    func claudeUsageFollowsSelectedHost() {
        let store = MemoryHostStore()
        store.hosts = [Self.studio]
        let demoConsent = InMemoryHostWriteConsentStore()
        let hostConsent = InMemoryHostWriteConsentStore()
        hostConsent.grant(ClaudeUsageHost.feature.id, host: Self.studio.id.uuidString)
        let model = HostsModel(store: store, demoChannel: FakeHost(), demoConsent: demoConsent, hostConsent: hostConsent,
                               makeChannel: ChannelFactory(FakeHost()).make)

        model.load()
        #expect(model.claudeUsage.state == .on)

        model.select(.demo)
        #expect(model.claudeUsage.state == .off)
        demoConsent.grant(ClaudeUsageHost.feature.id, host: "demo")
        model.select(.demo)
        #expect(model.claudeUsage.state == .on)
    }

    @Test("移除主機：從儲存刪除、清除該主機的所有主機寫入同意，選取改回其他主機或 Demo")
    func removingHostRevokesConsent() async throws {
        let store = MemoryHostStore()
        var other = Self.studio
        other.id = UUID()
        other.name = "Zeta"
        store.hosts = [Self.studio, other]
        let hostConsent = InMemoryHostWriteConsentStore()
        hostConsent.grant(ClaudeUsageHost.feature.id, host: Self.studio.id.uuidString)
        hostConsent.grant("theme", host: Self.studio.id.uuidString)
        hostConsent.grant(ClaudeUsageHost.feature.id, host: other.id.uuidString)
        let model = HostsModel(store: store, demoChannel: FakeHost(), hostConsent: hostConsent, makeChannel: ChannelFactory(FakeHost(), FakeHost()).make)
        model.load()

        try await model.delete(Self.studio.id)

        #expect(store.hosts.map(\.id) == [other.id])
        #expect(model.rows.map(\.id) == [other.id])
        #expect(model.selection == .host(other.id))
        #expect(!hostConsent.isGranted(ClaudeUsageHost.feature.id, host: Self.studio.id.uuidString))
        #expect(!hostConsent.isGranted("theme", host: Self.studio.id.uuidString))
        #expect(hostConsent.isGranted(ClaudeUsageHost.feature.id, host: other.id.uuidString))

        try await model.delete(other.id)
        #expect(model.selection == .demo)
    }
}
