import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// HTTPS 主機的新增聊天與 workspace／worktree 操作在畫面上的呈現(#287):版本不足顯示更新提示、唯讀裝置停用並說明。
@MainActor
@Suite("HTTPS 主機的結構操作畫面")
struct HTTPSStructureActionsTests {
    /// 仿 HTTPS 主機連線：每個 herdr 請求都以 `error` 失敗;唯讀照 `readOnly` 回報。
    struct RefusingHostConnection: HostConnection {
        let error: any Error
        var readOnly = false

        func isReadOnlyDevice() async throws -> Bool { readOnly }
        func herdrRequest(_ request: Data, deadline: Duration) async throws -> Data { throw error }
        func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error> { throw error }
        func readTranscript(_ request: TranscriptRequest) async throws -> Data { throw error }
        func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection { throw error }
        func disconnect() async {}
    }

    private static let outdated = HostServiceError.hostServiceUpdateRequired(.workspaceOperations, installedVersion: "0.6.0")

    private static func actions(_ connection: RefusingHostConnection) -> WorkspaceActionsModel {
        WorkspaceActionsModel(client: HerdrClient(connection: connection), preferences: InMemoryChatPreferencesStore())
    }

    private static func newChat(_ connection: RefusingHostConnection) -> NewChatModel {
        let folders = NewChatFolders.absolutePathsOnly
        return NewChatModel(launcher: NewChatLauncher(client: HerdrClient(connection: connection), folders: folders), folders: folders)
    }

    // MARK: - workspace 操作

    @Test("主機服務版本不足：改名失敗顯示更新主機服務的提示，不是「連不到 herdr」")
    func renameOnOutdatedHostService() async {
        let actions = Self.actions(RefusingHostConnection(error: Self.outdated))

        #expect(await actions.rename(workspaceID: "w1", to: "garden-notes") == false)

        #expect(actions.renameError == HostErrorText.message(for: Self.outdated))
    }

    @Test("主機服務版本不足：Tab 改名失敗顯示更新主機服務的提示(#458)")
    func renameTabOnOutdatedHostService() async {
        let error = HostServiceError.hostServiceUpdateRequired(.tabRename, installedVersion: "0.13.0")
        let actions = Self.actions(RefusingHostConnection(error: error))

        #expect(await actions.renameTab(tabID: "w1:t1", to: "build-logs") == false)

        #expect(actions.renameError == HostErrorText.message(for: error))
    }

    @Test("唯讀裝置：Tab 改名被拒時說明唯讀(#458)")
    func renameTabOnReadOnlyDevice() async {
        let actions = Self.actions(RefusingHostConnection(error: HostServiceError.readOnlyDevice, readOnly: true))
        await actions.loadAccess()

        #expect(actions.isReadOnly)
        #expect(await actions.renameTab(tabID: "w1:t1", to: "build-logs") == false)
        #expect(actions.renameError == HostErrorText.message(for: HostServiceError.readOnlyDevice))
    }

    @Test("唯讀裝置：讀到唯讀後停用改到主機的操作;關閉被拒時說明唯讀")
    func readOnlyDeviceActions() async {
        let actions = Self.actions(RefusingHostConnection(error: HostServiceError.readOnlyDevice, readOnly: true))
        #expect(!actions.isReadOnly)

        await actions.loadAccess()
        await actions.close(workspaceID: "w1", sessionIDs: [])

        #expect(actions.isReadOnly)
        #expect(actions.actionError == WorkspaceActionsModel.readOnlyMessage)
        #expect(WorkspaceActionsModel.readOnlyMessage == HostErrorText.message(for: HostServiceError.readOnlyDevice))
    }

    // MARK: - 新增聊天

    @Test("沒有資料夾瀏覽的主機：不提供瀏覽;`~` 開頭的資料夾要求改成完整路徑")
    func newChatNeedsAbsolutePath() async {
        let model = Self.newChat(RefusingHostConnection(error: Self.outdated))
        model.folder = "~/Projects"
        model.message = "hi"

        #expect(!model.canBrowseFolders)
        #expect(await model.start() == nil)
        #expect(model.error == NewChatModel.message(for: NewChatFolderError.absolutePathRequired("~/Projects")))
        #expect(model.error != NewChatModel.message(for: HostServiceError.unsupported("folders")))
    }

    @Test("主機服務說資料夾不存在：顯示「主機上沒有這個資料夾」")
    func newChatInMissingFolder() async {
        let model = Self.newChat(RefusingHostConnection(error: HerdrError.herdr(code: "folder_not_found", message: "cwd must be …")))
        model.folder = "/Users/demo/gone"
        model.message = "hi"

        _ = await model.start()

        #expect(model.error == NewChatModel.message(for: NewChatFolderError.notFound("/Users/demo/gone")))
    }

    @Test("主機服務版本不足：新增聊天顯示更新主機服務的提示")
    func newChatOnOutdatedHostService() async {
        let model = Self.newChat(RefusingHostConnection(error: Self.outdated))
        model.folder = "/Users/demo/Projects"
        model.message = "hi"

        _ = await model.start()

        #expect(model.error == HostErrorText.message(for: Self.outdated))
    }

    @Test("唯讀裝置：讀到唯讀後不能開始，說明原因")
    func newChatOnReadOnlyDevice() async {
        let model = Self.newChat(RefusingHostConnection(error: HostServiceError.readOnlyDevice, readOnly: true))
        model.folder = "/Users/demo/Projects"
        model.message = "hi"
        #expect(model.canStart)

        await model.loadAccess()

        #expect(!model.canStart)
        #expect(model.readOnlyReason == HostErrorText.message(for: HostServiceError.readOnlyDevice))
    }

    @Test("HTTPS 主機的新增聊天沒有資料夾瀏覽;SSH 主機有")
    func hostsModelNewChatFolders() {
        let https = HostConfiguration(name: "Studio", hostService: HostServiceAddress("studio.tail1234.ts.net")!)
        let ssh = HostConfiguration(name: "SSH", endpoint: SSHEndpoint(host: "studio-mac", username: "ray"))
        let store = MemoryHostStore()
        store.hosts = [https, ssh]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        model.load()

        #expect(!model.newChat(on: .host(https.id)).canBrowseFolders)
        #expect(model.newChat(on: .host(ssh.id)).canBrowseFolders)
    }

    @Test("HTTPS 主機沒有 tab.create:不提供「在此新增聊天」;SSH 主機提供(#537)")
    func hostsModelNewChatInWorkspaceSupport() {
        let https = HostConfiguration(name: "Studio", hostService: HostServiceAddress("studio.tail1234.ts.net")!)
        let ssh = HostConfiguration(name: "SSH", endpoint: SSHEndpoint(host: "studio-mac", username: "ray"))
        let store = MemoryHostStore()
        store.hosts = [https, ssh]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        model.load()

        #expect(!model.supportsNewChatInWorkspace(.host(https.id)))
        #expect(model.supportsNewChatInWorkspace(.host(ssh.id)))
    }

    @Test("新增聊天的主機挑選鈕可指定偏好主機(Workspace 標題選單進來時,#537)")
    func newChatPickerPreferringHost() {
        let first = HostConfiguration(name: "A", endpoint: SSHEndpoint(host: "a", username: "ray"))
        let second = HostConfiguration(name: "B", endpoint: SSHEndpoint(host: "b", username: "ray"))
        let store = MemoryHostStore()
        store.hosts = [first, second]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        model.load()

        #expect(model.newChatHostPicker(preferring: .host(second.id)).selection == .host(second.id))
    }
}
