import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 存在記憶體裡的主機儲存(Seam 3 平台服務的假實作)。
@MainActor
final class MemoryHostStore: HostStore {
    var hosts: [HostConfiguration] = []
    var saveError: (any Error)?
    var deleteError: (any Error)?

    func loadHosts() throws -> [HostConfiguration] { hosts }

    func save(_ host: HostConfiguration) throws {
        if let saveError { throw saveError }
        hosts.removeAll { $0.id == host.id }
        hosts.append(host)
    }

    func delete(_ id: UUID) throws {
        if let deleteError { throw deleteError }
        hosts.removeAll { $0.id == id }
    }
}

/// 記錄 model 用哪個 pin、哪個憑證來源開了哪些連線。依建立順序給出假主機(主機清單依名稱排序建立)。
@MainActor
final class ChannelFactory {
    var hosts: [FakeHost]
    private(set) var pins: [HostKeyFingerprint?] = []
    private(set) var endpoints: [SSHEndpoint] = []
    private(set) var credentials: [SSHCredentialProvider] = []

    init(_ hosts: FakeHost...) { self.hosts = hosts }

    func make(_ endpoint: SSHEndpoint, _ pin: HostKeyFingerprint?, _ credential: @escaping SSHCredentialProvider) -> any HostChannel {
        endpoints.append(endpoint)
        pins.append(pin)
        credentials.append(credential)
        // 多主機合併列表(#39)會替每台已存主機建立通道;沒指定的主機給一個空的假主機。
        return hosts.isEmpty ? FakeHost() : hosts.removeFirst()
    }
}

struct SaveFailed: Error {}

@MainActor
@Suite("新增主機(Tailscale SSH)")
struct HostEditorModelTests {
    static let fingerprint = HostKeyFingerprint(stored: "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww")!
    static let otherFingerprint = HostKeyFingerprint(stored: "d3UZ4WSMqwA9f7HNdFV7b3Dde7LFqimgoeahTmn0d0I")!

    static func healthyHost(_ herdr: HerdrInstallation = HerdrInstallation()) async -> FakeHost {
        let host = FakeHost()
        await host.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("Darwin\n".utf8)))
        await host.expect(HerdrCommand.version(herdr), reply: FakeReply(stdout: Data("herdr 0.9.5\n".utf8)))
        await host.expect(HerdrCommand.bridge(herdr), reply: .recorded("ping.ndjson"))
        await host.expect(HerdrCommand.bridge(herdr), reply: .recorded("session.snapshot.ndjson"))
        await host.expect(HerdrCommand.bridge(herdr), reply: .recorded("integration.list.ndjson"))
        return host
    }

    static func unverifiedHost() async -> FakeHost {
        let host = FakeHost()
        await host.failConnection(with: SSHConnectionError.hostKeyUnverified(presented: fingerprint))
        return host
    }

    static func fill(_ model: HostEditorModel, session: String = "") {
        model.name = "Studio"
        model.address = "ray-mac-mini"
        model.username = "demo"
        model.herdrSession = session
    }

    @Test("第一次連線先確認 host key 指紋，確認後才登入測試;儲存時存下 pin、herdr 設定與 OS")
    func firstConnectionConfirmsHostKeyThenSaves() async throws {
        let store = MemoryHostStore()
        let healthy = await Self.healthyHost(HerdrInstallation(session: "work"))
        let factory = ChannelFactory(await Self.unverifiedHost(), healthy)
        let model = HostEditorModel(store: store, makeChannel: factory.make)
        Self.fill(model, session: "work")

        await model.test()
        #expect(model.phase == .confirmHostKey(Self.fingerprint))
        #expect(!model.canSave)

        await model.trustPresentedHostKey()

        guard case .tested(let report) = model.phase else { Issue.record("測試沒有成功:\(model.phase)"); return }
        #expect(report.herdrVersion == HerdrVersion("0.9.5"))
        #expect(factory.pins == [nil, Self.fingerprint])
        #expect(factory.endpoints.first == SSHEndpoint(host: "ray-mac-mini", port: 22, username: "demo"))
        #expect(await healthy.disconnectCount == 1, "測試用的暫時連線沒有拆掉")

        let saved = try #require(model.save())
        #expect(store.hosts == [saved])
        #expect(saved.hostKeyPin == Self.fingerprint)
        #expect(saved.herdr == HerdrInstallation(session: "work"))
        #expect(saved.operatingSystem == .macOS)
        #expect(saved.name == "Studio")
    }

    @Test("連線測試之後改了任何欄位，就要重新測試才能儲存")
    func editingInvalidatesTest() async {
        let factory = ChannelFactory(await Self.healthyHost())
        let model = HostEditorModel(store: MemoryHostStore(), editing: HostConfiguration(
            name: "Studio", endpoint: SSHEndpoint(host: "ray-mac-mini", username: "demo"), hostKeyPin: Self.fingerprint),
            makeChannel: factory.make)

        await model.test()
        #expect(model.canSave)
        model.herdrPath = "/opt/homebrew/bin/herdr"
        #expect(!model.canSave)
        #expect(model.save() == nil)
    }

    @Test("編輯主機只改名稱時沿用已存的 pin;改了位址才重新確認")
    func pinIsKeptUnlessEndpointChanges() async {
        let existing = HostConfiguration(
            name: "Studio", endpoint: SSHEndpoint(host: "ray-mac-mini", username: "demo"), hostKeyPin: Self.fingerprint)
        let factory = ChannelFactory(await Self.healthyHost(), await Self.unverifiedHost())
        let model = HostEditorModel(store: MemoryHostStore(), editing: existing, makeChannel: factory.make)

        model.name = "Studio Mac"
        await model.test()
        model.address = "100.64.0.9"
        await model.test()

        #expect(factory.pins == [Self.fingerprint, nil])
        #expect(model.phase == .confirmHostKey(Self.fingerprint))
    }

    @Test("指紋改變時阻擋並警告，顯示目前出示與已存的指紋;只 pin 剛剛出示的那一把")
    func changedHostKeyIsBlocked() async throws {
        let existing = HostConfiguration(
            name: "Studio", endpoint: SSHEndpoint(host: "ray-mac-mini", username: "demo"), hostKeyPin: Self.fingerprint)
        let changed = FakeHost()
        await changed.failConnection(with: SSHConnectionError.hostKeyChanged(presented: Self.otherFingerprint, pinned: Self.fingerprint))
        let factory = ChannelFactory(changed, await Self.healthyHost())
        let model = HostEditorModel(store: MemoryHostStore(), editing: existing, makeChannel: factory.make)

        await model.test()
        #expect(model.phase == .hostKeyChanged(presented: Self.otherFingerprint, pinned: Self.fingerprint))
        #expect(!model.canSave)

        await model.trustPresentedHostKey()
        #expect(factory.pins == [Self.fingerprint, Self.otherFingerprint])
        #expect(model.save()?.hostKeyPin == Self.otherFingerprint)
    }

    @Test("herdr 低於 0.9.5:提示版本，使用者確認後才執行 herdr update,再重新測試")
    func outdatedHerdrUpdatesAfterConfirmation() async {
        let herdr = HerdrInstallation()
        let old = FakeHost()
        await old.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("Darwin\n".utf8)))
        await old.expect(HerdrCommand.version(herdr), reply: FakeReply(stdout: Data("herdr 0.9.3\n".utf8)))
        let updater = FakeHost()
        await updater.expect(HerdrCommand.update(herdr), reply: FakeReply(stdout: Data("installed 0.9.5\n".utf8)))
        let factory = ChannelFactory(old, updater, await Self.healthyHost())
        let model = HostEditorModel(store: MemoryHostStore(), editing: HostConfiguration(
            name: "Studio", endpoint: SSHEndpoint(host: "ray-mac-mini", username: "demo"), hostKeyPin: Self.fingerprint),
            makeChannel: factory.make)

        await model.test()
        #expect(model.phase == .needsUpdate(HerdrVersion("0.9.3")!))
        #expect(await updater.executions.isEmpty, "還沒確認就更新了")

        await model.updateHerdr()

        #expect(await updater.executions.map(\.command) == [HerdrCommand.update(herdr)])
        #expect(model.canSave)
    }

    @Test("連不上時留在編輯器並說明原因，不顯示函式庫的錯誤字串")
    func connectionFailureExplainsWhy() async {
        let refused = FakeHost()
        await refused.failConnection(with: SSHConnectionError.connectionRefused)
        let model = HostEditorModel(store: MemoryHostStore(), makeChannel: ChannelFactory(refused).make)
        Self.fill(model)

        await model.test()

        guard case .failed(let message) = model.phase else { Issue.record("\(model.phase)"); return }
        #expect(message.contains("SSH"))
    }

    @Test("儲存失敗(例如 Keychain 拒絕)時留在編輯器並說明原因")
    func saveFailureStaysInEditor() async {
        let store = MemoryHostStore()
        store.saveError = SaveFailed()
        let model = HostEditorModel(store: store, editing: HostConfiguration(
            name: "Studio", endpoint: SSHEndpoint(host: "ray-mac-mini", username: "demo"), hostKeyPin: Self.fingerprint),
            makeChannel: ChannelFactory(await Self.healthyHost()).make)

        await model.test()
        #expect(model.save() == nil)
        guard case .failed = model.phase else { Issue.record("\(model.phase)"); return }
    }

    @Test("必填欄位(名稱、位址、使用者名稱)與埠 1–65535 才能測試")
    func requiredFields() {
        let model = HostEditorModel(store: MemoryHostStore(), makeChannel: ChannelFactory().make)
        #expect(!model.canTest)
        Self.fill(model)
        #expect(model.canTest)
        model.port = "70000"
        #expect(!model.canTest)
    }
}
