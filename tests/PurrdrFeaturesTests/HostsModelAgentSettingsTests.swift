#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機的 Agent 設定在 `HostsModel` 的行為(#477):預設、存讀、新增主機的偵測、既有主機的初始化、
/// 新增聊天與用量的過濾,以及主機同步不洗掉本機設定。
@MainActor
@Suite("主機的 Agent 設定(HostsModel)")
struct HostsModelAgentSettingsTests {
    final class Recorder: HostChangeRecorder {
        var saved: [UUID] = []
        func hostSaved(_ id: UUID) { saved.append(id) }
        func hostDeleted(_ id: UUID) {}
    }

    static func host(enabled: Set<AgentID>? = nil) -> HostConfiguration {
        HostConfiguration(
            name: "Studio", connection: .tailscaleSSH(.init(endpoint: SSHEndpoint(host: "studio-mac", username: "demo"))),
            operatingSystem: .macOS, enabledAgents: enabled)
    }

    static func model(
        _ host: HostConfiguration, channel: FakeHost = FakeHost(), store: MemoryHostStore = MemoryHostStore()
    ) -> (HostsModel, MemoryHostStore) {
        store.hosts = [host]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(channel).make)
        model.load()
        return (model, store)
    }

    @Test("沒設定過的主機沿用升級前的行為;設定過以設定為準;範例主機全開")
    func enabledAgentsDefaults() {
        let legacy = Self.host()
        let (model, _) = Self.model(legacy)
        #expect(model.enabledAgents(on: .host(legacy.id)) == [.claude, .codex])
        #expect(model.enabledAgents(on: .demo) == Set(HostAgentSettings.configurable))
        let (configured, _) = Self.model(Self.host(enabled: [.agy]))
        #expect(configured.enabledAgents(on: configured.selection) == [.agy])
    }

    @Test("改設定存進主機設定,不算主機的修改(不同步)、不重建連線")
    func settingPersistsWithoutSyncing() throws {
        let host = Self.host(enabled: [.claude])
        let (model, store) = Self.model(host)
        let recorder = Recorder()
        model.changeRecorder = recorder
        model.setEnabledAgents([.claude, .agy], for: host.id)
        #expect(store.hosts.first?.enabledAgents == [.claude, .agy])
        #expect(model.enabledAgents(on: .host(host.id)) == [.claude, .agy])
        #expect(recorder.saved.isEmpty)
    }

    @Test("新增主機:偵測到的 Agent 預先打開,沒偵測到的關閉")
    func newHostPreselectsDetected() async {
        let channel = FakeHost()
        await channel.serveHomeFiles(directories: [".claude", ".gemini", ".gemini/antigravity-cli"])
        let host = Self.host()
        let (model, store) = Self.model(host, channel: channel)
        await model.initializeAgentSettings(for: host.id, isNewHost: true)
        #expect(store.hosts.first?.enabledAgents == [.claude, .agy])
    }

    @Test("既有主機升級:目前顯示用量的 Claude Code 與 Codex 加上偵測到的")
    func existingHostMigrates() async {
        let channel = FakeHost()
        await channel.serveHomeFiles(directories: [".gemini", ".gemini/antigravity-cli"])
        let host = Self.host()
        let (model, store) = Self.model(host, channel: channel)
        await model.initializeAgentSettings(for: host.id, isNewHost: false)
        #expect(store.hosts.first?.enabledAgents == [.claude, .codex, .agy])
    }

    @Test("已經設定過就不再偵測、不覆蓋使用者的選擇")
    func configuredHostIsLeftAlone() async {
        let channel = FakeHost()
        await channel.serveHomeFiles(directories: [".claude"])
        let host = Self.host(enabled: [])
        let (model, store) = Self.model(host, channel: channel)
        await model.initializeAgentSettings(for: host.id, isNewHost: false)
        #expect(store.hosts.first?.enabledAgents == [])
        #expect(await channel.executions.isEmpty)
    }

    @Test("偵測不到(主機離線):不寫入,維持還沒設定,下次再偵測")
    func offlineKeepsUnconfigured() async {
        let channel = FakeHost()
        await channel.failConnection(with: FakeHostError.unexpectedCommand("offline"))
        let host = Self.host()
        let (model, store) = Self.model(host, channel: channel)
        await model.initializeAgentSettings(for: host.id, isNewHost: true)
        #expect(store.hosts.first?.enabledAgents == nil)
    }

    @Test("HTTPS 主機:以列表讀到的快照裡出現過的種類偵測,不另外搶讀快照;還沒讀到就不寫")
    func httpsDetectsFromSnapshot() async {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        let model = HostOverviewTests.httpsModel(connection: connection)
        let id = HostOverviewTests.buildBox.id
        await model.initializeAgentSettings(for: id, isNewHost: true)
        #expect(model.hosts.first?.enabledAgents == nil, "快照還沒讀到,不該另外去讀、也不該寫入")
        #expect(await connection.requests.isEmpty)
        await model.agentList.load()
        await model.initializeAgentSettings(for: id, isNewHost: true)
        #expect(model.hosts.first?.enabledAgents == [.claude])
    }

    @Test("HTTPS 主機:快照裡當下沒有任何 Agent 時不寫入空集合,維持還沒設定(新增聊天仍有預設的 Agent)")
    func httpsEmptySnapshotDoesNotInitialize() async {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.modifiedLine("session.snapshot.ndjson") {
            SnapshotEdit.removeAgents(in: &$0)
        })
        let model = HostOverviewTests.httpsModel(connection: connection)
        let id = HostOverviewTests.buildBox.id
        await model.agentList.load()
        await model.initializeAgentSettings(for: id, isNewHost: true)
        #expect(model.hosts.first?.enabledAgents == nil)
        #expect(model.enabledAgents(on: .host(id)) == [.claude, .codex])
    }

    @Test("HTTPS 偵測重試每秒一次、最多 10 次,等待用注入的 sleep(不真的等)")
    func httpsDetectionRetriesUseInjectedSleep() async {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.modifiedLine("session.snapshot.ndjson") { SnapshotEdit.removeAgents(in: &$0) })
        let sleeper = RecordingSleeper(fires: { _ in true })
        let model = HostOverviewTests.httpsModel(connection: connection, sleep: sleeper.sleep)
        await model.agentList.load()

        await model.initializeAgentSettingsWhenReachable(for: HostOverviewTests.buildBox.id, isNewHost: true)

        #expect(await sleeper.requested == Array(repeating: .seconds(1), count: 9))
        #expect(model.hosts.first?.enabledAgents == nil)
    }

    @Test("HTTPS 偵測第一次就成功:不等待")
    func httpsDetectionSucceedsWithoutSleeping() async {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        let sleeper = RecordingSleeper(fires: { _ in true })
        let model = HostOverviewTests.httpsModel(connection: connection, sleep: sleeper.sleep)
        await model.agentList.load()

        await model.initializeAgentSettingsWhenReachable(for: HostOverviewTests.buildBox.id, isNewHost: true)

        #expect(await sleeper.requested.isEmpty)
        #expect(model.hosts.first?.enabledAgents == [.claude])
    }

    @Test("方案用量頁的 Agent 清單只列這台主機啟用的(#477)")
    func planUsageListsOnlyEnabledAgents() {
        let host = Self.host(enabled: [.codex])
        let (model, _) = Self.model(host)
        let usage = model.screens.planUsage(host: .host(host.id))
        #expect(usage.agents == [.codex])
        #expect(usage.agent == .codex)
    }

    @Test("新增聊天只列這台主機啟用的 Agent")
    func newChatListsOnlyEnabled() {
        let host = Self.host(enabled: [.codex, .agy])
        let (model, _) = Self.model(host)
        let chat = model.member(for: .host(host.id)).newChat()
        #expect(chat.availableAgents == [.codex, .agy])
        #expect(chat.agent == .codex)
    }

    @Test("新增聊天:全部關閉就沒有可選的 Agent,不能開始")
    func newChatWithNothingEnabled() {
        let host = Self.host(enabled: [])
        let (model, _) = Self.model(host)
        let chat = model.member(for: .host(host.id)).newChat()
        #expect(chat.availableAgents.isEmpty)
        chat.folder = "/Users/demo/app"
        chat.message = "hi"
        #expect(chat.canStart == false)
    }

    @Test("用量區只列(也只查)啟用的 Agent")
    func usageSectionSkipsDisabled() {
        let host = Self.host(enabled: [.claude])
        let (model, _) = Self.model(host)
        let section = model.member(for: .host(host.id)).usageSection(agents: PlanUsageAgent.allCases)
        #expect(section.agents == [.claudeCode])
    }
}
#endif
