import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 管理多台主機(#10、行為規格 F1.1、F1.3):切換、重新命名、刪除、選取持久化、匯入分享連結。
@MainActor
@Suite("管理多台主機")
struct HostManagementTests {
    static let studio = HostsModelTests.studio
    static let linux = HostConfiguration(
        name: "Linux box", endpoint: SSHEndpoint(host: "100.64.0.9", port: 2222, username: "ops"), operatingSystem: .linux)

    static func model(
        hosts: [HostConfiguration], selection: any HostSelectionStore = InMemoryHostSelectionStore(),
        cache: any ConversationCache = InMemoryConversationCache(), channels: ChannelFactory
    ) -> (HostsModel, MemoryHostStore) {
        let store = MemoryHostStore()
        store.hosts = hosts
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), conversationCache: cache, selectionStore: selection, makeChannel: channels.make)
        return (model, store)
    }

    @Test("選取中主機存在本機：重新啟動後選回同一台(不是第一台)")
    func selectionIsPersisted() {
        let selection = InMemoryHostSelectionStore()
        let (first, _) = Self.model(hosts: [Self.studio, Self.linux], selection: selection, channels: ChannelFactory(FakeHost(), FakeHost()))
        first.load()
        #expect(first.selection == .host(Self.linux.id), "依名稱排序，第一台是 Linux box")

        first.select(.host(Self.studio.id))
        let (relaunched, _) = Self.model(hosts: [Self.studio, Self.linux], selection: selection, channels: ChannelFactory(FakeHost()))
        relaunched.load()

        #expect(relaunched.selection == .host(Self.studio.id))
    }

    @Test("存的選取是已刪除的主機：改選第一台剩餘主機")
    func staleSelectionFallsBack() {
        let selection = InMemoryHostSelectionStore(.host(UUID()))
        let (model, _) = Self.model(hosts: [Self.studio], selection: selection, channels: ChannelFactory(FakeHost()))

        model.load()

        #expect(model.selection == .host(Self.studio.id))
        #expect(selection.load() == .host(Self.studio.id))
    }

    @Test("切換主機後再切回來，沿用那台主機的連線(不重新撥號);每台主機各自一條通道")
    func eachHostKeepsItsOwnChannel() {
        let factory = ChannelFactory(FakeHost(), FakeHost())
        let (model, _) = Self.model(hosts: [Self.studio, Self.linux], channels: factory)
        model.load()

        model.select(.host(Self.studio.id))
        model.select(.host(Self.linux.id))

        #expect(factory.endpoints == [Self.linux, Self.studio].compactMap(\.ssh?.endpoint))
    }

    @Test("重新命名：只改名稱並存回，選取與連線不變")
    func renameKeepsConnection() throws {
        let factory = ChannelFactory(FakeHost())
        let (model, store) = Self.model(hosts: [Self.studio], channels: factory)
        model.load()

        try model.rename(Self.studio.id, to: "  Office Mac  ")

        #expect(store.hosts.map(\.name) == ["Office Mac"])
        #expect(store.hosts.first?.ssh?.hostKeyPin == Self.studio.ssh?.hostKeyPin)
        #expect(model.rows.map(\.title) == ["Office Mac"])
        #expect(model.selection == .host(Self.studio.id))
        #expect(factory.endpoints.count == 1, "改名稱不該重建連線")
    }

    @Test("名稱空白不能重新命名")
    func blankNameIsRejected() {
        let (model, store) = Self.model(hosts: [Self.studio], channels: ChannelFactory(FakeHost()))
        model.load()

        #expect(throws: HostManagementError.emptyName) { try model.rename(Self.studio.id, to: "   ") }
        #expect(store.hosts.map(\.name) == ["Studio"])
    }

    @Test("刪除選取中主機：刪掉儲存的設定、關閉連線、清掉它的對話快取，選取改為剩下的第一台並存起來")
    func deleteSelectedHost() async throws {
        let studioChannel = FakeHost()
        let selection = InMemoryHostSelectionStore()
        let cache = InMemoryConversationCache()
        let (model, store) = Self.model(
            hosts: [Self.studio, Self.linux], selection: selection, cache: cache, channels: ChannelFactory(FakeHost(), studioChannel))
        model.load()
        model.select(.host(Self.studio.id))
        let cached = CachedConversation(sessionID: "s1", messages: [], metadata: TranscriptMetadata(), path: "/x", cursor: 0, windowStart: 0)
        await model.conversationCache(for: .host(Self.studio.id)).save(cached, chatKey: "w1:p1")
        await model.conversationCache(for: .host(Self.linux.id)).save(cached, chatKey: "w1:p1")

        try await model.delete(Self.studio.id)

        #expect(store.hosts.map(\.id) == [Self.linux.id])
        #expect(model.rows.map(\.id) == [Self.linux.id])
        #expect(await studioChannel.disconnectCount == 1)
        #expect(await model.conversationCache(for: .host(Self.studio.id)).load(chatKey: "w1:p1") == nil)
        #expect(await model.conversationCache(for: .host(Self.linux.id)).load(chatKey: "w1:p1") == cached, "刪了別台主機的快取")
        #expect(model.selection == .host(Self.linux.id))
        #expect(selection.load() == .host(Self.linux.id))
    }

    @Test("刪除用密碼加入過公鑰的主機：另開連線拿掉這支裝置加入的那一行(ADR-0002 還原)")
    func deleteRestoresInstalledDeviceKey() async throws {
        let deviceKey = EphemeralDeviceKey(comment: "purrdr@iPhone")
        let otherKeys = Data("ssh-ed25519 AAAAother laptop\n".utf8)
        let target = FakeHost()
        await target.serveHomeFiles([".ssh/authorized_keys": otherKeys], directories: [".ssh"])
        try await AuthorizedKeyInstaller(channel: target).install(try deviceKey.publicKey())
        let office = HostConfiguration(
            name: "Office", endpoint: SSHEndpoint(host: "office", username: "demo"), openSSH: .deviceKey, operatingSystem: .linux)
        let consent = InMemoryHostWriteConsentStore()
        consent.grant(AuthorizedKeyInstaller.feature.id, host: office.id.uuidString)
        let store = MemoryHostStore()
        store.hosts = [office]
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), hostConsent: consent, credentials: HostCredentials(deviceKey: deviceKey),
            makeChannel: ChannelFactory(target, target).make)
        model.load()

        try await model.delete(office.id)

        await LoginShellModelTests.eventually { await target.homeFiles == [".ssh/authorized_keys": otherKeys] }
        #expect(await target.homeFiles == [".ssh/authorized_keys": otherKeys])
    }

    @Test("刪除沒同意加入公鑰的主機：不另開連線改 authorized_keys")
    func deleteWithoutKeyConsentLeavesHostAlone() async throws {
        let target = FakeHost()
        await target.serveHomeFiles()
        let factory = ChannelFactory(target, target)
        let office = HostConfiguration(
            name: "Office", endpoint: SSHEndpoint(host: "office", username: "demo"), openSSH: .deviceKey, operatingSystem: .linux)
        let store = MemoryHostStore()
        store.hosts = [office]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: factory.make)
        model.load()

        try await model.delete(office.id)

        #expect(await target.executions.isEmpty)
    }

    @Test("刪除最後一台主機：改選 Demo 主機並存起來")
    func deleteLastHostSelectsDemo() async throws {
        let selection = InMemoryHostSelectionStore()
        let (model, store) = Self.model(hosts: [Self.studio], selection: selection, channels: ChannelFactory(FakeHost()))
        model.load()

        try await model.delete(Self.studio.id)

        #expect(store.hosts.isEmpty)
        #expect(model.selection == .demo)
        #expect(selection.load() == .demo)
    }

    @Test("刪除沒選取的主機：選取不變")
    func deleteOtherHostKeepsSelection() async throws {
        let (model, _) = Self.model(hosts: [Self.studio, Self.linux], channels: ChannelFactory(FakeHost()))
        model.load()

        try await model.delete(Self.studio.id)

        #expect(model.selection == .host(Self.linux.id))
    }

    @Test("刪除時儲存寫入失敗：主機留在清單，丟出錯誤讓畫面說明")
    func deleteFailureKeepsHost() async {
        let (model, store) = Self.model(hosts: [Self.studio], channels: ChannelFactory(FakeHost()))
        model.load()
        store.deleteError = SaveFailed()

        await #expect(throws: SaveFailed.self) { try await model.delete(Self.studio.id) }
        #expect(model.rows.map(\.id) == [Self.studio.id])
    }

    @Test("編輯既有主機儲存後：關掉舊設定的連線，以新設定重建")
    func editRebuildsConnection() async throws {
        let old = FakeHost()
        let factory = ChannelFactory(old, FakeHost())
        let (model, store) = Self.model(hosts: [Self.studio], channels: factory)
        model.load()

        let edited = Self.studio.editingSSH { $0.endpoint.port = 2200 }
        store.hosts = [edited]
        model.didSave(edited)

        #expect(factory.endpoints.last == edited.ssh?.endpoint)
        try await waitUntil { await old.disconnectCount == 1 }
    }

    @Test("匯入分享連結：開新增主機的編輯器並帶入欄位(仍要連線測試才能儲存)")
    func importOpensPrefilledEditor() throws {
        let (model, _) = Self.model(hosts: [], channels: ChannelFactory())
        let url = HostShareLink.url(for: Self.studio)

        let editor = try model.screens.makeImportEditor(url)

        #expect(editor.name == "Studio")
        #expect(editor.address == "studio-mac")
        #expect(editor.port == "22")
        #expect(editor.username == "demo")
        #expect(editor.herdrSession == "work")
        #expect(editor.isEditing == false)
        #expect(editor.canSave == false)
        #expect(editor.hostKeyFingerprint == Self.studio.ssh?.hostKeyPin)
    }

    @Test("匯入 OpenSSH 主機的分享連結：連線方式帶入 OpenSSH,不是預設的 Tailscale SSH")
    func importKeepsConnectionMethod() throws {
        let (model, _) = Self.model(hosts: [], channels: ChannelFactory())
        let shared = SharedHost(
            name: "Office", endpoint: SSHEndpoint(host: "office.example", port: 22, username: "ray"), connectionMethod: .openSSH)

        let editor = try model.screens.makeImportEditor(HostShareLink.url(for: shared))

        #expect(editor.connectionMethod == .openSSH)
    }

    @Test("分享連結：選取中主機的連結就是 HostShareLink 的內容")
    func shareLinkForHost() {
        let (model, _) = Self.model(hosts: [Self.studio], channels: ChannelFactory(FakeHost()))
        model.load()

        #expect(model.shareLink(for: Self.studio.id) == HostShareLink.url(for: Self.studio))
    }
}
