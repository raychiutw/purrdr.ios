#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機能力 adapter(#563):每種連線方式交出哪些能力、沒有的原因,以及成員只依能力組建立。
@MainActor
@Suite("主機能力 adapter")
struct HostAdaptersTests {
    static let sshHost = HostConfiguration(
        name: "Studio", endpoint: SSHEndpoint(host: "studio-mac", username: "demo"), operatingSystem: .macOS)
    static let httpsHost = HostConfiguration(
        name: "Box", hostService: HostServiceAddress(host: "box.tail1234.ts.net", port: 443)!)

    func environment(connection: (any HostConnection)? = nil) -> HostAdapterEnvironment {
        let access = connection.map { fake in HostServiceAccess(tokens: InMemoryDeviceTokenStore()) { _, _ in fake } }
            ?? HostServiceAccess(tokens: InMemoryDeviceTokenStore())
        return HostAdapterEnvironment(
            makeChannel: { _, _, _ in FakeHost() }, credentials: HostCredentials(), hostService: access, pushService: nil,
            traffic: HostTrafficWiring(meter: { nil }), diagnostics: .system(category: "test"),
            recordOperatingSystem: { _, _ in }, consent: InMemoryHostWriteConsentStore())
    }

    @Test("SSH 主機:有推播外掛、測試通知、Antigravity 狀態;沒有 Send When Done 與主機服務連線")
    func sshOffersChannelCapabilities() {
        let caps = SSHHostAdapter(environment: environment()).capabilities(for: Self.sshHost)
        #expect(caps.pushInstaller.value != nil)
        #expect(caps.pushTestSender.value != nil)
        #expect(caps.antigravityStatus.value != nil)
        #expect(caps.sendWhenDone.gap == .notOfferedByConnectionMethod)
        #expect(caps.hostServiceConnection.gap == .notOfferedByConnectionMethod)
    }

    @Test("HTTPS 主機:有 Send When Done、主機服務連線與測試通知;沒有 Antigravity 狀態")
    func httpsOffersHostServiceCapabilities() {
        let caps = HTTPSHostAdapter(environment: environment()).capabilities(for: Self.httpsHost)
        #expect(caps.sendWhenDone.value != nil)
        #expect(caps.hostServiceConnection.value != nil)
        #expect(caps.pushTestSender.value != nil)
        #expect(caps.pushInstaller.value != nil)
        #expect(caps.antigravityStatus.gap == .notOfferedByConnectionMethod)
    }

    @Test("HTTPS 主機的替身連線(沒實作這些能力):每項都說明原因,不是安靜地少一個功能")
    func httpsWithPlainConnectionExplainsGaps() {
        let caps = HTTPSHostAdapter(environment: environment(connection: FakeHostConnection()))
            .capabilities(for: Self.httpsHost)
        #expect(caps.sendWhenDone.gap == .connectionLacksSupport)
        #expect(caps.pushTestSender.gap == .connectionLacksSupport)
        #expect(caps.hostServiceConnection.gap == .connectionLacksSupport)
    }

    @Test("主機設定的能力(主題、You should know、Codex 啟動器):SSH 與 Demo 提供,HTTPS 不提供(#730)")
    func machineSettingsOfferedOnlyWithChannel() {
        let ssh = SSHHostAdapter(environment: environment()).capabilities(for: Self.sshHost)
        let https = HTTPSHostAdapter(environment: environment()).capabilities(for: Self.httpsHost)
        let httpsPlain = HTTPSHostAdapter(environment: environment(connection: FakeHostConnection())).capabilities(for: Self.httpsHost)
        let demo = DemoHostAdapter(channel: FakeHost(), files: UnsupportedHostFileFetcher(), consent: InMemoryHostWriteConsentStore())
        #expect(ssh.machineSettings.value != nil)
        #expect(demo.demoHostCapabilities().machineSettings.value != nil)
        #expect(demo.companionCapabilities(channel: FakeHost()).machineSettings.value != nil)
        #expect(https.machineSettings.gap == .notOfferedByConnectionMethod)
        #expect(httpsPlain.machineSettings.gap == .notOfferedByConnectionMethod)
    }

    @Test("成員:HTTPS 主機的設定頁沒有主題、You should know、Codex 啟動器;聊天沒有註記;SSH 都有(#730)")
    func memberHidesMachineSettingsOverHTTPS() {
        func member(_ host: HostConfiguration, _ caps: HostCapabilities) -> HostMember {
            let environment = HostMemberEnvironment(
                isSavedHost: { _ in true },
                offlineQueue: { OfflineQueue(host: $0.storedValue, store: InMemoryOfflineQueueStore()) { _, _ in .notSent(.rejected("")) } })
            return HostMember(
                host: .host(host.id), hostID: host.id.uuidString, capabilities: caps, preferences: InMemoryChatPreferencesStore(),
                push: nil, environment: environment)
        }
        let https = member(Self.httpsHost, HTTPSHostAdapter(environment: environment()).capabilities(for: Self.httpsHost))
        let httpsSettings = https.settings()
        #expect(httpsSettings != nil, "用量擷取仍在設定頁")
        #expect(httpsSettings?.hostTheme == nil)
        #expect(httpsSettings?.youShouldKnow == nil)
        #expect(httpsSettings?.codexLauncher == nil)
        #expect(!https.offersMachineSettings)
        #expect(https.conversation(ChatRoute(host: .host(Self.httpsHost.id), paneID: "w1:p1"), sessionID: nil).youShouldKnow == nil)

        let ssh = member(Self.sshHost, SSHHostAdapter(environment: environment()).capabilities(for: Self.sshHost))
        let sshSettings = ssh.settings()
        #expect(sshSettings?.hostTheme != nil)
        #expect(sshSettings?.youShouldKnow != nil)
        #expect(sshSettings?.codexLauncher != nil)
        #expect(ssh.offersMachineSettings)
        #expect(ssh.conversation(ChatRoute(host: .host(Self.sshHost.id), paneID: "w1:p1"), sessionID: nil).youShouldKnow != nil)
    }

    @Test("HTTPS 連線以主機 id 重用;丟掉後重新建立")
    func httpsReusesConnectionPerHost() async throws {
        let adapter = HTTPSHostAdapter(environment: environment())
        let first = try #require(adapter.connection(for: Self.httpsHost))
        #expect(try #require(adapter.connection(for: Self.httpsHost)) as AnyObject === first as AnyObject)
        await adapter.drop(Self.httpsHost.id)?.value
        #expect(try #require(adapter.connection(for: Self.httpsHost)) as AnyObject !== first as AnyObject)
    }

    @Test("SSH 通道以主機 id 重用,並能列出給喚醒探測")
    func sshReusesChannelPerHost() {
        let adapter = SSHHostAdapter(environment: environment())
        _ = adapter.capabilities(for: Self.sshHost)
        _ = adapter.capabilities(for: Self.sshHost)
        #expect(adapter.liveChannels.keys.contains(Self.sshHost.id))
        #expect(adapter.liveChannels.count == 1)
    }

    @Test("Demo 主機:沒有真的後端,沒有的能力原因是 demoHost")
    func demoExplainsGaps() {
        let adapter = DemoHostAdapter(channel: FakeHost(), files: UnsupportedHostFileFetcher(), consent: InMemoryHostWriteConsentStore())
        for caps in [adapter.demoHostCapabilities(), adapter.companionCapabilities(channel: FakeHost())] {
            #expect(caps.pushTestSender.gap == .demoHost)
            #expect(caps.sendWhenDone.gap == .demoHost)
            #expect(caps.hostServiceConnection.gap == .demoHost)
            #expect(caps.pushInstaller.value != nil)
        }
    }

    @Test("成員以假能力組建立:沒有的能力在成員上就是沒有,不經連線方式判斷")
    func memberBuildsFromCapabilitiesOnly() {
        var caps = SSHHostAdapter(environment: environment()).capabilities(for: Self.sshHost)
        caps.antigravityStatus = .unavailable(.demoHost)
        caps.sendWhenDone = .unavailable(.connectionLacksSupport)
        let member = HostMember(
            host: .host(Self.sshHost.id), hostID: Self.sshHost.id.uuidString, capabilities: caps,
            preferences: InMemoryChatPreferencesStore(), push: nil)
        #expect(member.antigravityStatus == nil)
        #expect(member.sendWhenDoneHost == nil)
        #expect(member.capabilities.sendWhenDone.gap == .connectionLacksSupport)
    }

    @Test("連線方式固定的性質由 adapter 回答:主機服務與 Agent 偵測方式")
    func adaptersAnswerConnectionTraits() {
        let ssh = SSHHostAdapter(environment: environment())
        let https = HTTPSHostAdapter(environment: environment())
        #expect(ssh.traits.usesHostService == false)
        #expect(ssh.traits.agentDetection == .configFolders)
        #expect(ssh.traits.agentDetection.attempts == 1)
        #expect(https.traits.usesHostService)
        #expect(https.traits.agentDetection == .snapshot(attempts: 10))
    }

    @Test("清單列的位址:SSH 是 帳號@主機:埠,HTTPS 是主機服務位址")
    func adaptersDescribeAddress() {
        #expect(SSHHostAdapter(environment: environment()).addressDescription(of: Self.sshHost) == "demo@studio-mac:22")
        #expect(
            HTTPSHostAdapter(environment: environment()).addressDescription(of: Self.httpsHost)
                == Self.httpsHost.hostService?.description)
    }

    @Test("成員的新增聊天資料夾來自能力組:HTTPS 只收完整路徑")
    func memberFoldersComeFromCapabilities() {
        let https = HTTPSHostAdapter(environment: environment()).capabilities(for: Self.httpsHost)
        let member = HostMember(
            host: .host(Self.httpsHost.id), hostID: Self.httpsHost.id.uuidString, capabilities: https,
            preferences: InMemoryChatPreferencesStore(), push: nil)
        #expect(member.capabilities.folders.canBrowse == false)
        let ssh = SSHHostAdapter(environment: environment()).capabilities(for: Self.sshHost)
        #expect(ssh.folders.canBrowse)
    }
}
#endif
