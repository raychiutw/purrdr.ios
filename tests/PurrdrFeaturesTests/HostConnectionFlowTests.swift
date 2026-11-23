import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrHTTPS
import PurrdrTestSupport
import Testing

/// 連線測試、主機身分確認、herdr 版本檢查與儲存的共用流程(#340):新增主機引導與主機編輯頁共用，
/// 這裡不經編輯頁 model,直接餵一份連線草稿。
@MainActor
@Suite("主機連線流程")
struct HostConnectionFlowTests {
    static let fingerprint = HostEditorModelTests.fingerprint
    static let otherFingerprint = HostEditorModelTests.otherFingerprint
    static let endpoint = SSHEndpoint(host: "studio-mac", port: 22, username: "demo")

    /// 預設是 Tailscale SSH;`openSSH` 為 `true` 時是以密碼登入的 OpenSSH。
    static func sshDraft(pin: HostKeyFingerprint? = nil, openSSH: Bool = false) -> HostConnectionDraft {
        let settings = HostConfiguration.SSHSettings(endpoint: endpoint, herdr: HerdrInstallation(), hostKeyPin: pin)
        let authentication: HostConfiguration.OpenSSHAuthentication? = openSSH ? .password : nil
        return HostConnectionDraft(name: "Studio", connection: .ssh(SSHConnectionDraft(settings: settings, authentication: authentication)))
    }

    static func flow(store: MemoryHostStore = MemoryHostStore(), factory: ChannelFactory) -> HostConnectionFlow {
        HostConnectionFlow(store: store, credentials: HostCredentials(), hostService: HostServiceAccess(), makeChannel: factory.make)
    }

    @Test("OpenSSH 第一次連線停在主機身分確認;信任後以那把 key 為 pin 重測、通過後儲存帶 pin 與作業系統")
    func confirmsIdentityThenSaves() async throws {
        let store = MemoryHostStore()
        let healthy = await HostEditorModelTests.healthyHost()
        let factory = ChannelFactory(await HostEditorModelTests.unverifiedHost(), healthy)
        let flow = Self.flow(store: store, factory: factory)
        let draft = Self.sshDraft(openSSH: true)

        await flow.test(draft)
        #expect(flow.phase == .confirmHostKey(Self.fingerprint))
        #expect(!flow.canSave(draft))

        #expect(flow.trustPresentedHostKey(for: draft))
        let trusted = Self.sshDraft(pin: Self.fingerprint, openSSH: true)
        await flow.test(trusted)
        guard case .tested = flow.phase else { Issue.record("應該通過測試:\(flow.phase)"); return }
        #expect(factory.pins == [nil, Self.fingerprint])

        let saved = try #require(flow.save(trusted))
        #expect(saved.ssh?.hostKeyPin == Self.fingerprint)
        #expect(saved.operatingSystem == .macOS)
        #expect(store.hosts == [saved])
    }

    @Test("編輯已存的主機:儲存後保留這台主機的 Agent 設定(#477)")
    func editingKeepsAgentSettings() async throws {
        let store = MemoryHostStore()
        var existing = HostConfiguration(name: "Studio", endpoint: Self.endpoint)
        existing.enabledAgents = [.agy]
        store.hosts = [existing]
        let factory = ChannelFactory(await HostEditorModelTests.unverifiedHost(), await HostEditorModelTests.healthyHost())
        let flow = HostConnectionFlow(
            store: store, existing: existing, credentials: HostCredentials(), hostService: HostServiceAccess(), makeChannel: factory.make)
        await flow.test(Self.sshDraft())
        let saved = try #require(flow.save(Self.sshDraft(pin: Self.fingerprint)))
        #expect(saved.enabledAgents == [.agy])
        #expect(store.hosts.first?.enabledAgents == [.agy])
    }

    @Test("Tailscale SSH 第一次連線不問,自動記住出示的 key(仍 pin),重測通過後儲存帶 pin")
    func tailscaleRemembersFirstKeyWithoutAsking() async throws {
        let store = MemoryHostStore()
        let factory = ChannelFactory(await HostEditorModelTests.unverifiedHost(), await HostEditorModelTests.healthyHost())
        let flow = Self.flow(store: store, factory: factory)

        await flow.test(Self.sshDraft())

        guard case .tested = flow.phase else { Issue.record("不該停在確認:\(flow.phase)"); return }
        #expect(factory.pins == [nil, Self.fingerprint])
        let remembered = Self.sshDraft(pin: Self.fingerprint)
        let saved = try #require(flow.save(remembered))
        #expect(saved.ssh?.hostKeyPin == Self.fingerprint)
    }

    @Test("指紋變了就阻擋、不能信任新 key;兩種連線方式都一樣")
    func changedKeyBlocks() async throws {
        for openSSH in [false, true] {
            let changed = FakeHost()
            await changed.failConnection(with: SSHConnectionError.hostKeyChanged(presented: Self.otherFingerprint, pinned: Self.fingerprint))
            let factory = ChannelFactory(changed, await HostEditorModelTests.healthyHost())
            let flow = Self.flow(factory: factory)
            let draft = Self.sshDraft(pin: Self.fingerprint, openSSH: openSSH)

            #expect(!flow.trustPresentedHostKey(for: draft))
            await flow.test(draft)
            #expect(flow.phase == .hostKeyChanged(presented: Self.otherFingerprint, pinned: Self.fingerprint))
            #expect(!flow.canSave(draft))
            // 一鍵略過的路:信任出示的 key 後重測,不能成立。
            #expect(!flow.trustPresentedHostKey(for: draft), "指紋變了不能信任新 key")
            #expect(flow.accepted == nil)
            #expect(factory.pins == [Self.fingerprint], "不該以新 key 重測")
        }
    }

    @Test("改了草稿之後要重測才能儲存")
    func editingInvalidatesTest() async throws {
        let flow = Self.flow(factory: ChannelFactory(await HostEditorModelTests.healthyHost()))
        let draft = Self.sshDraft(pin: Self.fingerprint)
        await flow.test(draft)
        #expect(flow.canSave(draft))
        var edited = draft
        edited.name = "Other"
        #expect(!flow.canSave(edited))
        #expect(flow.save(edited) == nil)
        // 只改連線設定(例如 herdr session)、名稱不變，也要重測。
        guard case .ssh(var ssh) = draft.connection else { return }
        ssh.settings.herdr = HerdrInstallation(session: "work")
        let reconfigured = HostConnectionDraft(name: draft.name, connection: .ssh(ssh))
        #expect(!flow.canSave(reconfigured))
    }
}
