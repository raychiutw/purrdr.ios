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

    static func sshDraft(pin: HostKeyFingerprint? = nil) -> HostConnectionDraft {
        let settings = HostConfiguration.SSHSettings(endpoint: endpoint, herdr: HerdrInstallation(), hostKeyPin: pin)
        return HostConnectionDraft(name: "Studio", connection: .ssh(SSHConnectionDraft(settings: settings)))
    }

    static func flow(store: MemoryHostStore = MemoryHostStore(), factory: ChannelFactory) -> HostConnectionFlow {
        HostConnectionFlow(store: store, credentials: HostCredentials(), hostService: HostServiceAccess(), makeChannel: factory.make)
    }

    @Test("第一次連線停在主機身分確認;信任後以那把 key 為 pin 重測、通過後儲存帶 pin 與作業系統")
    func confirmsIdentityThenSaves() async throws {
        let store = MemoryHostStore()
        let healthy = await HostEditorModelTests.healthyHost()
        let factory = ChannelFactory(await HostEditorModelTests.unverifiedHost(), healthy)
        let flow = Self.flow(store: store, factory: factory)

        await flow.test(Self.sshDraft())
        #expect(flow.phase == .confirmHostKey(Self.fingerprint))
        #expect(!flow.canSave(Self.sshDraft()))

        #expect(flow.trustPresentedHostKey(for: Self.sshDraft()))
        let trusted = Self.sshDraft(pin: Self.fingerprint)
        await flow.test(trusted)
        guard case .tested = flow.phase else { Issue.record("應該通過測試:\(flow.phase)"); return }
        #expect(factory.pins == [nil, Self.fingerprint])

        let saved = try #require(flow.save(trusted))
        #expect(saved.ssh?.hostKeyPin == Self.fingerprint)
        #expect(saved.operatingSystem == .macOS)
        #expect(store.hosts == [saved])
    }

    @Test("指紋變了就阻擋;沒有出示的 key 時不能信任")
    func changedKeyBlocks() async throws {
        let changed = FakeHost()
        await changed.failConnection(with: SSHConnectionError.hostKeyChanged(presented: Self.otherFingerprint, pinned: Self.fingerprint))
        let flow = Self.flow(factory: ChannelFactory(changed))
        let draft = Self.sshDraft(pin: Self.fingerprint)

        #expect(!flow.trustPresentedHostKey(for: draft))
        await flow.test(draft)
        #expect(flow.phase == .hostKeyChanged(presented: Self.otherFingerprint, pinned: Self.fingerprint))
        #expect(!flow.canSave(draft))
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
