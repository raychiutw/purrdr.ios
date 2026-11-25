import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

@MainActor
@Suite("主機清單")
struct HostsModelTests {
    static let pin = HostKeyFingerprint(stored: "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww")!
    static let studio = HostConfiguration(
        name: "Studio", endpoint: SSHEndpoint(host: "studio-mac", username: "demo"),
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
        await real.expect(HerdrCommand.bridge(HerdrInstallation(session: "work")), reply: .recorded("session.snapshot.ndjson"))
        let factory = ChannelFactory(real)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: factory.make)

        model.load()
        await model.agentList.load()

        #expect(model.selection == .host(Self.studio.id))
        #expect(factory.endpoints == [Self.studio].compactMap(\.ssh?.endpoint))
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

    @Test("偵測到的作業系統存不進這支裝置：留下診斷紀錄，這次執行仍用偵測結果")
    func detectedOperatingSystemSaveFailureIsLogged() async throws {
        var synced = Self.studio
        synced.operatingSystem = nil
        let store = MemoryHostStore()
        store.hosts = [synced]
        let real = FakeHost()
        await real.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("Linux\n".utf8)))
        await real.expect(HerdrCommand.bridge(HerdrInstallation(session: "work")), reply: .recorded("session.snapshot.ndjson"))
        let log = RecordingDiagnosticLog()
        let model = HostsModel(store: store, demoChannel: FakeHost(), diagnostics: log.log, makeChannel: ChannelFactory(real).make)
        model.load()
        store.saveError = SaveFailed()

        await model.agentList.load()

        #expect(model.hosts.first?.operatingSystem == .linux)
        #expect(store.hosts.first?.operatingSystem == nil)
        #expect(log.messages.count == 1)
        #expect(log.messages.first?.contains("operating system") == true, "\(log.messages)")
    }

    @Test("作業系統未知、偵測到 macOS／Linux:之後照常送 POSIX 指令(#26)")
    func unknownOperatingSystemDetectsPosix() async throws {
        var synced = Self.studio
        synced.operatingSystem = nil
        let store = MemoryHostStore()
        store.hosts = [synced]
        let real = FakeHost()
        await real.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("Linux\n".utf8)))
        await real.expect(HerdrCommand.bridge(HerdrInstallation(session: "work")), reply: .recorded("session.snapshot.ndjson"))
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

        let shell = model.loginShell(on: model.selection)
        shell.viewDidResize(columns: 80, rows: 24)
        let files = model.folderBrowser(on: model.selection)
        await files.load()
        #expect(await real.waitForPTYs(1) == 1)

        #expect(shell.title == "Studio")
        #expect(files.hostName == "Studio")
        #expect(files.path == "/Users/demo")
        #expect(await real.unmetExpectations.isEmpty)
    }

    @Test("主機沒有 gzip 時記住：再開一次檔案瀏覽，上傳直接用 identity")
    func filesRemembersHostWithoutGzip() async throws {
        let store = MemoryHostStore()
        store.hosts = [Self.studio]
        let real = FakeHost()
        let log = Data(String(repeating: "purrdr upload log line\n", count: 200).utf8)
        let transfer = UploadTransfer.prepare(log, named: "first.log", deflate: SystemDeflate())
        let home = FakeReply(stdout: Data("/Users/demo\n".utf8))
        for _ in 0..<2 {
            await real.expect(HostFolderCommand.list(nil), reply: home)
            await real.expect(HostFolderCommand.list("/Users/demo"), reply: home)
        }
        await real.expect(
            HostFolderCommand.upload(folder: "/Users/demo", name: "first.log", size: log.count, encoding: .gzip, transferSize: transfer.payload.count),
            reply: FakeReply(exitCode: 69))
        await real.expect(
            HostFolderCommand.upload(folder: "/Users/demo", name: "first.log", size: log.count),
            reply: FakeReply(stdout: Data("/Users/demo/first.log\n".utf8)))
        await real.expect(
            HostFolderCommand.upload(folder: "/Users/demo", name: "second.log", size: log.count),
            reply: FakeReply(stdout: Data("/Users/demo/second.log\n".utf8)))
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(real).make)
        model.load()

        let first = model.folderBrowser(on: model.selection)
        await first.load()
        await first.upload(log, named: "first.log")
        let second = model.folderBrowser(on: model.selection)
        await second.load()
        await second.upload(log, named: "second.log")

        #expect(transfer.encoding == .gzip)
        #expect(await real.unmetExpectations.isEmpty)
        #expect(await real.executions.count == 7)
    }

    @Test("檔案瀏覽上傳文字檔時以 gzip 傳輸(系統 DEFLATE)")
    func filesUploadUsesGzip() async throws {
        let store = MemoryHostStore()
        store.hosts = [Self.studio]
        let real = FakeHost()
        let log = Data(String(repeating: "purrdr upload log line\n", count: 200).utf8)
        let transfer = UploadTransfer.prepare(log, named: "build.log", deflate: SystemDeflate())
        await real.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data("/Users/demo\n".utf8)))
        await real.expect(
            HostFolderCommand.upload(folder: "/Users/demo", name: "build.log", size: log.count, encoding: .gzip, transferSize: transfer.payload.count),
            reply: FakeReply(stdout: Data("/Users/demo/build.log\n".utf8)))
        await real.expect(HostFolderCommand.list("/Users/demo"), reply: FakeReply(stdout: Data("/Users/demo\n".utf8)))
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(real).make)
        model.load()

        let files = model.folderBrowser(on: model.selection)
        await files.load()
        await files.upload(log, named: "build.log")

        #expect(transfer.encoding == .gzip)
        #expect(await real.executions.dropFirst().first?.stdin == transfer.payload)
        #expect(await real.unmetExpectations.isEmpty)
    }

    @Test("新增對話開在選取中主機(帶 herdr session);開始後重讀列表並開那個 pane 的聊天")
    func newChatUsesSelectedHostAndOpensChat() async throws {
        let store = MemoryHostStore()
        store.hosts = [Self.studio]
        let real = FakeHost()
        let bridge = HerdrCommand.bridge(HerdrInstallation(session: "work"))
        await real.expect(NewChatFolders.command(for: "~/ledger"), reply: FakeReply(stdout: NewChatFolders.output(path: "/Users/demo/ledger", folders: [])))
        let created = #"{"id":"purrdr:workspace.create","result":{"type":"workspace_created","workspace":{"workspace_id":"w4","number":4,"label":"ledger","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w4:t1","agent_status":"unknown"},"root_pane":{"pane_id":"w4:p1","terminal_id":"t","workspace_id":"w4","tab_id":"w4:t1","focused":false,"agent_status":"unknown","revision":0}}}"#
        await real.expect(bridge, reply: FakeReply(stdout: Data(created.utf8) + [0x0A], trigger: .afterStdinLine))
        await real.expect(bridge, reply: FakeReply(stdout: Data(#"{"id":"purrdr:agent.start","result":{"type":"agent_started"}}"#.utf8) + [0x0A], trigger: .afterStdinLine))
        await real.expect(bridge, reply: FakeReply(stdout: Data(#"{"id":"purrdr:agent.prompt","result":{"type":"agent_prompted","delivery":"submitted"}}"#.utf8) + [0x0A], trigger: .afterStdinLine))
        await real.expect(bridge, reply: .recorded("session.snapshot.ndjson"))
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(real).make)
        model.load()

        let newChat = model.newChat(on: model.selection)
        newChat.folder = "~/ledger"
        newChat.message = "Fix the CSV quoting"
        let workspace = try #require(await newChat.start())
        await model.openStartedChat(workspace, on: model.selection)

        #expect(model.agentList.openedChat == ChatRoute(host: .host(Self.studio.id), paneID: "w4:p1"))
        #expect(model.agentList.list(for: .host(Self.studio.id))?.phase == .loaded)
        #expect(await real.unmetExpectations.isEmpty)
    }

    @Test("主機清單依名稱排序，每列顯示名稱、user@host:port,設了具名 session 就附註(#37 故事 24)")
    func rowsShowEndpointAndSession() {
        let store = MemoryHostStore()
        var plain = Self.studio.editingSSH {
            $0.endpoint = SSHEndpoint(host: "100.64.0.9", port: 2222, username: "ops")
            $0.herdr = HerdrInstallation()
        }
        plain.id = UUID()
        plain.name = "Linux box"
        store.hosts = [Self.studio, plain]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost()).make)

        model.load()

        #expect(model.rows == [
            HostRow(id: plain.id, title: "Linux box", subtitle: "ops@100.64.0.9:2222", session: nil, isSelected: true),
            HostRow(id: Self.studio.id, title: "Studio", subtitle: "demo@studio-mac:22", session: "work", isSelected: false),
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

    @Test("Demo 也演出多主機(#34):沒有已存主機時，列表合併 Demo 與示範主機(含一台連不上);主機清單沒有它們;新增主機後消失")
    func demoShowsCompanionHosts() async throws {
        let store = MemoryHostStore()
        let demo = FakeHost()
        await demo.expect(HerdrCommand.bridge(), reply: .recorded("session.snapshot.ndjson"))
        let studio = FakeHost()
        await studio.expect(HerdrCommand.bridge(), reply: .recorded("session.snapshot.ndjson"))
        let buildBox = FakeHost()
        await buildBox.failConnection(with: SSHConnectionError.timedOut)
        let companions = [
            DemoCompanionHost(id: UUID(), name: "Studio Mac", icon: .macMini, channel: studio),
            DemoCompanionHost(id: UUID(), name: "Build Box", icon: .rack, channel: buildBox),
        ]
        let model = HostsModel(
            store: store, demoChannel: demo, demoCompanions: companions, makeChannel: ChannelFactory(FakeHost()).make)

        model.load()
        await model.agentList.load()

        #expect(model.selection == .demo)
        #expect(model.agentList.sources.map(\.name) == ["Demo", "Studio Mac", "Build Box"])
        #expect(model.agentList.sections.flatMap(\.rows).count == 6)
        #expect(model.agentList.failures.map(\.name) == ["Build Box"])
        #expect(model.rows.isEmpty, "示範主機不是已存主機，不出現在主機清單")
        let window = PaneWindow(kind: .chat, host: .host(companions[0].id), paneID: "w1:p1", sessionID: nil, title: "ledger")
        #expect(window.route(hostIDs: model.listedHostIDs) != nil, "示範主機的聊天在新視窗開不起來")

        store.hosts = [Self.studio]
        model.didSave(Self.studio)
        #expect(model.agentList.sources.map(\.name) == ["Studio"])
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
            "The host didn’t answer in time. Make sure it’s awake and Tailscale is on for both devices."))
    }

    static let httpsStudio = HostConfiguration(
        id: UUID(uuidString: "1D2E3F40-5A6B-4C7D-8E9F-0A1B2C3D4E5F")!, name: "Studio HTTPS",
        hostService: HostServiceAddress("studio.tail1234.ts.net")!)

    @Test("同步後需要重新確認的主機：所有主機選單的選項都標出來，沒被標記的不標(#572)")
    func hostOptionsFlagHostsNeedingReconfirmation() {
        var flagged = Self.httpsStudio
        flagged.needsReconfirmation = true
        let store = MemoryHostStore()
        store.hosts = [Self.studio, flagged]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost()).make)
        model.load()

        let flags = { (options: [HostOption]) in options.map { [$0.id: $0.needsReconfirmation] } }
        let expected = [[HostSelection.demo: false], [.host(Self.studio.id): false], [.host(flagged.id): true]]
        #expect(flags(model.selectedHostPicker().options) == expected)
        #expect(flags(model.newChatHostPicker().options) == expected)
        #expect(flags(model.planUsage().hosts) == expected)
        #expect(flags(model.dataUsage().hosts) == expected)
        #expect(model.agentList.hostFilterOptions.filter(\.needsReconfirmation).map(\.id) == [.host(flagged.id)])
    }

    @Test("方案用量畫面：主機選單列出 Demo 與所有已存主機，預設選取中主機，記住上次選擇")
    func planUsageListsAllHosts() {
        let store = MemoryHostStore()
        store.hosts = [Self.studio, Self.httpsStudio]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost()).make)
        model.load()

        let usage = model.planUsage()
        #expect(usage.hosts.map(\.id) == [.demo, .host(Self.studio.id), .host(Self.httpsStudio.id)])
        #expect(usage.hosts.map(\.name) == ["Demo", "Studio", "Studio HTTPS"])
        #expect(usage.host == model.selection)

        usage.select(host: .demo)
        usage.disappeared()
        #expect(model.planUsage().host == .demo)
    }

    @Test("方案用量的查詢成本：Demo 主機不耗 token 與傳輸，SSH 主機需要傳輸;HTTPS 主機不支援、不連線")
    func planUsageCostFollowsConnection() async {
        let store = MemoryHostStore()
        store.hosts = [Self.studio, Self.httpsStudio]
        let real = FakeHost()
        let hostConsent = InMemoryHostWriteConsentStore()
        hostConsent.grant(ClaudePlanUsageHost.feature.id, host: Self.httpsStudio.id.uuidString)
        let model = HostsModel(store: store, demoChannel: FakeHost(), hostConsent: hostConsent, makeChannel: ChannelFactory(real).make)
        model.load()
        let usage = model.planUsage()
        usage.appeared()

        #expect(usage.cost == .transfer)
        usage.select(host: .demo)
        #expect(usage.cost == .free)
        usage.select(host: .host(Self.httpsStudio.id))
        await usage.untilIdle()
        #expect(usage.cost == nil)
        #expect(usage.state == .unsupportedConnection)
        usage.disappeared()
        #expect(await real.executions.isEmpty)
    }

    @Test("Codex 的方案用量：SSH 主機經主機通道(需要傳輸)、Demo 主機不耗 token 與傳輸;HTTPS 主機不支援")
    func codexPlanUsageFollowsConnection() async {
        let store = MemoryHostStore()
        store.hosts = [Self.studio, Self.httpsStudio]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost()).make)
        model.load()
        let usage = model.planUsage()
        usage.select(agent: .codex)

        #expect(usage.cost == .transfer)
        usage.select(host: .demo)
        #expect(usage.cost == .free)
        usage.select(host: .host(Self.httpsStudio.id))
        #expect(usage.cost == nil)
        usage.disappeared()
    }

    @Test("移除主機：從儲存刪除、清除該主機的所有主機寫入同意，選取改回其他主機或 Demo")
    func removingHostRevokesConsent() async throws {
        let store = MemoryHostStore()
        var other = Self.studio
        other.id = UUID()
        other.name = "Zeta"
        store.hosts = [Self.studio, other]
        let hostConsent = InMemoryHostWriteConsentStore()
        hostConsent.grant(ClaudePlanUsageHost.feature.id, host: Self.studio.id.uuidString)
        hostConsent.grant("theme", host: Self.studio.id.uuidString)
        hostConsent.grant(ClaudePlanUsageHost.feature.id, host: other.id.uuidString)
        let model = HostsModel(store: store, demoChannel: FakeHost(), hostConsent: hostConsent, makeChannel: ChannelFactory(FakeHost(), FakeHost()).make)
        model.load()

        try await model.delete(Self.studio.id)

        #expect(store.hosts.map(\.id) == [other.id])
        #expect(model.rows.map(\.id) == [other.id])
        #expect(model.selection == .host(other.id))
        #expect(!hostConsent.isGranted(ClaudePlanUsageHost.feature.id, host: Self.studio.id.uuidString))
        #expect(!hostConsent.isGranted("theme", host: Self.studio.id.uuidString))
        #expect(hostConsent.isGranted(ClaudePlanUsageHost.feature.id, host: other.id.uuidString))

        try await model.delete(other.id)
        #expect(model.selection == .demo)
    }
}

/// 記下診斷紀錄(不給使用者看的那種)。
@MainActor
final class RecordingDiagnosticLog {
    private(set) var messages: [String] = []
    var log: DiagnosticLog { DiagnosticLog { [weak self] message in self?.messages.append(message) } }
}
