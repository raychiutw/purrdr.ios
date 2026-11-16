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
        #expect(model.agentList.list(for: model.selection)?.phase == .loaded)
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

    @Test("Windows 主機(連線測試偵測到的 OS):Agent 列表的 herdr 指令換成 PowerShell -EncodedCommand(#26)")
    func windowsHostUsesPowerShell() async throws {
        var pc = Self.studio
        pc.operatingSystem = .windows
        let store = MemoryHostStore()
        store.hosts = [pc]
        let real = FakeHost()
        await real.expect(
            PowerShell.encodedCommand(HostEditorModelTests.windowsHerdrScript("'--session' 'work' 'remote-api-bridge'")),
            reply: .recorded("session.snapshot.ndjson"))
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(real).make)

        model.load()
        await model.agentList.load()

        #expect(model.agentList.sections.flatMap(\.rows).count == 3)
        #expect(await real.unmetExpectations.isEmpty)
    }

    @Test("作業系統未知的主機(主機同步帶來的新主機):先偵測，偵測到 Windows 就不送 POSIX 指令，並記住 OS(#26)")
    func unknownOperatingSystemIsDetectedBeforeCommands() async throws {
        var synced = Self.studio
        synced.operatingSystem = nil
        let store = MemoryHostStore()
        store.hosts = [synced]
        let real = FakeHost()
        await real.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("MINGW64_NT-10.0-19045\n".utf8)))
        await real.expect(
            PowerShell.encodedCommand(HostEditorModelTests.windowsHerdrScript("'--session' 'work' 'remote-api-bridge'")),
            reply: .recorded("session.snapshot.ndjson"))
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(real).make)

        model.load()
        await model.agentList.load()

        #expect(model.agentList.sections.flatMap(\.rows).count == 3)
        #expect(await real.unmetExpectations.isEmpty)
        #expect(store.hosts.first?.operatingSystem == .windows, "偵測結果存起來，下次不必再偵測")
        #expect(model.hosts.first?.operatingSystem == .windows)
    }

    @Test("作業系統未知、偵測到 macOS／Linux:之後照常送 POSIX 指令(#26)")
    func unknownOperatingSystemDetectsPosix() async throws {
        var synced = Self.studio
        synced.operatingSystem = nil
        let store = MemoryHostStore()
        store.hosts = [synced]
        let real = FakeHost()
        await real.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("Linux\n".utf8)))
        await real.expect(HerdrCommand.bridge(Self.studio.herdr), reply: .recorded("session.snapshot.ndjson"))
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(real).make)

        model.load()
        await model.agentList.load()

        #expect(model.agentList.sections.flatMap(\.rows).count == 3)
        #expect(await real.unmetExpectations.isEmpty)
        #expect(store.hosts.first?.operatingSystem == .linux)
    }

    @Test("登入 Shell 與檔案瀏覽開在選取中主機上，標題／副標是主機名稱")
    func loginShellAndFilesUseSelectedHost() async throws {
        let store = MemoryHostStore()
        store.hosts = [Self.studio]
        let real = FakeHost()
        await real.expectPTY(PTYRequest(columns: 80, rows: 24))
        await real.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data("/Users/demo\n".utf8)))
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(real).make)
        model.load()

        let shell = model.loginShell()
        shell.viewDidResize(columns: 80, rows: 24)
        let files = model.folderBrowser()
        await files.load()
        #expect(await real.waitForPTYs(1) == 1)

        #expect(shell.title == "Studio")
        #expect(files.hostName == "Studio")
        #expect(files.path == "/Users/demo")
        #expect(await real.unmetExpectations.isEmpty)
    }

    @Test("新增對話開在選取中主機(帶 herdr session);開始後重讀列表並開那個 pane 的聊天")
    func newChatUsesSelectedHostAndOpensChat() async throws {
        let store = MemoryHostStore()
        store.hosts = [Self.studio]
        let real = FakeHost()
        let bridge = HerdrCommand.bridge(Self.studio.herdr)
        await real.expect(NewChatFolders.command(for: "~/ledger"), reply: FakeReply(stdout: NewChatFolders.output(path: "/Users/demo/ledger", folders: [])))
        let created = #"{"id":"purrdr:workspace.create","result":{"type":"workspace_created","workspace":{"workspace_id":"w4","number":4,"label":"ledger","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w4:t1","agent_status":"unknown"},"root_pane":{"pane_id":"w4:p1","terminal_id":"t","workspace_id":"w4","tab_id":"w4:t1","focused":false,"agent_status":"unknown","revision":0}}}"#
        await real.expect(bridge, reply: FakeReply(stdout: Data(created.utf8) + [0x0A], trigger: .afterStdinLine))
        await real.expect(bridge, reply: FakeReply(stdout: Data(#"{"id":"purrdr:agent.start","result":{"type":"agent_started"}}"#.utf8) + [0x0A], trigger: .afterStdinLine))
        await real.expect(bridge, reply: .recorded("session.snapshot.ndjson"))
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(real).make)
        model.load()

        let newChat = model.newChat()
        newChat.folder = "~/ledger"
        let workspace = try #require(await newChat.start())
        await model.openStartedChat(workspace)

        #expect(model.agentList.openedChat == ChatRoute(host: .host(Self.studio.id), paneID: "w4:p1"))
        #expect(model.agentList.list(for: .host(Self.studio.id))?.phase == .loaded)
        #expect(await real.unmetExpectations.isEmpty)
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

        #expect(model.agentList.list(for: model.selection)?.phase == .failed(
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
