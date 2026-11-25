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
}
#endif
