import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 新增對話的表單與資料夾瀏覽(行為規格 F3.1、F3.3;#18)。
@MainActor
@Suite("新增對話")
struct NewChatModelTests {
    static let bridge = HerdrCommand.bridge()

    static func listing(_ path: String, _ folders: [String]) -> FakeReply {
        FakeReply(stdout: NewChatFolders.output(path: path, folders: folders))
    }

    static func model(_ host: FakeHost) -> NewChatModel {
        NewChatModel(
            launcher: NewChatLauncher(client: HerdrClient(channel: host), folders: NewChatFolders(channel: host)),
            folders: NewChatFolders(channel: host))
    }

    static func herdrError(_ method: String, code: String, message: String) -> FakeReply {
        FakeReply(stdout: Data(#"{"id":"purrdr:\#(method)","error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8) + [0x0A], trigger: .afterStdinLine)
    }

    // MARK: - 資料夾瀏覽

    @Test("一開始列出家目錄;點資料夾進去;上一層回到上層，在 / 不能再往上")
    func browsesFolders() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: ""), reply: Self.listing("/Users/demo", ["ledger", "notes"]))
        await host.expect(NewChatFolders.command(for: "/Users/demo/ledger"), reply: Self.listing("/Users/demo/ledger", []))
        await host.expect(NewChatFolders.command(for: "/Users/demo"), reply: Self.listing("/Users/demo", ["ledger", "notes"]))
        await host.expect(NewChatFolders.command(for: "/Users"), reply: Self.listing("/Users", ["demo"]))
        await host.expect(NewChatFolders.command(for: "/"), reply: Self.listing("/", ["Users"]))
        let picker = FolderPickerModel(folders: NewChatFolders(channel: host), start: nil)
        #expect(picker.state == .loading)
        #expect(!picker.canGoUp)

        await picker.load()
        #expect(picker.state == .loaded(NewChatFolderListing(path: "/Users/demo", folders: ["ledger", "notes"])))

        await picker.open("ledger")
        #expect(picker.state == .loaded(NewChatFolderListing(path: "/Users/demo/ledger", folders: [])))
        #expect(picker.chosenPath == "/Users/demo/ledger")

        await picker.goUp()
        await picker.goUp()
        await picker.goUp()
        #expect(picker.chosenPath == "/")
        #expect(!picker.canGoUp)
    }

    @Test("讀取錯誤與空資料夾是不同狀態：錯誤有說明、重試同一個資料夾")
    func errorIsNotEmpty() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/gone"), reply: FakeReply(exitCode: 66))
        await host.expect(NewChatFolders.command(for: "~/gone"), reply: FakeReply(stderr: Data("boom".utf8), exitCode: 1))
        await host.expect(NewChatFolders.command(for: "~/gone"), reply: Self.listing("/Users/demo/gone", []))
        let picker = FolderPickerModel(folders: NewChatFolders(channel: host), start: "~/gone")

        await picker.load()
        #expect(picker.state == .failed(String(localized: "This folder isn’t on the host, or you can’t open it.")))
        #expect(picker.chosenPath == nil)

        await picker.load()
        guard case .failed(let message) = picker.state else {
            Issue.record("應該是錯誤，不是 \(picker.state)")
            return
        }
        #expect(!message.isEmpty)

        await picker.load()
        #expect(picker.state == .loaded(NewChatFolderListing(path: "/Users/demo/gone", folders: [])))
    }

    @Test("在 / 底下開資料夾不會變成 //x")
    func opensFromRoot() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "/"), reply: Self.listing("/", ["Users"]))
        await host.expect(NewChatFolders.command(for: "/Users"), reply: Self.listing("/Users", []))
        let picker = FolderPickerModel(folders: NewChatFolders(channel: host), start: "/")

        await picker.load()
        await picker.open("Users")

        #expect(picker.chosenPath == "/Users")
    }

    // MARK: - 表單

    @Test("預設：Claude Code、權限模式沿用 agent 自己的設定(不是完全存取);資料夾空白不能開始")
    func defaults() {
        let model = Self.model(FakeHost())

        #expect(model.agent == .claude)
        #expect(model.permissionMode == .agentDefault)
        #expect(model.showsPermissionMode)
        #expect(!model.canStart)

        model.folder = "  "
        #expect(!model.canStart)
        model.folder = "~/ledger"
        #expect(model.canStart)

        model.agent = .codex
        #expect(!model.showsPermissionMode)
    }

    @Test("開始：以預設權限模式送出(沒有 --permission-mode),名稱修剪後空白就不帶 label,回傳新 workspace")
    func startsWithDefaults() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/ledger"), reply: Self.listing("/Users/demo/ledger", []))
        let created = #"{"id":"purrdr:workspace.create","result":{"type":"workspace_created","workspace":{"workspace_id":"w4","number":4,"label":"ledger","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w4:t1","agent_status":"unknown"},"tab":{"tab_id":"w4:t1","workspace_id":"w4","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"w4:p1","terminal_id":"term_0009","workspace_id":"w4","tab_id":"w4:t1","focused":false,"agent_status":"unknown","revision":0}}}"#
        await host.expect(Self.bridge, reply: FakeReply(stdout: Data(created.utf8) + [0x0A], trigger: .afterStdinLine))
        let started = #"{"id":"purrdr:agent.start","result":{"type":"agent_started","agent":{"pane_id":"w4:p1"},"argv":["claude"]}}"#
        await host.expect(Self.bridge, reply: FakeReply(stdout: Data(started.utf8) + [0x0A], trigger: .afterStdinLine))
        let model = Self.model(host)
        model.folder = " ~/ledger "
        model.name = "   "

        let workspace = await model.start()

        #expect(workspace == CreatedWorkspace(workspaceID: "w4", rootPaneID: "w4:p1"))
        #expect(model.error == nil)
        #expect(!model.isStarting)
        let executions = await host.executions
        #expect(!executions[1].stdinText.contains("label"))
        #expect(!executions[2].stdinText.contains("permission-mode"))
    }

    @Test("主機上沒有這個資料夾：說明並建議用資料夾瀏覽")
    func missingFolderMessage() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/nope"), reply: FakeReply(exitCode: 66))
        let model = Self.model(host)
        model.folder = "~/nope"

        #expect(await model.start() == nil)
        #expect(model.error == String(localized: "There’s no such folder on the host. Check the path, or choose a folder on the host."))
    }

    @Test("Demo 主機拒絕建立 workspace:說明要用自己的主機(翻譯過的文字，不是 herdr 原文)")
    func demoRejection() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/ledger"), reply: Self.listing("/Users/demo/ledger", []))
        await host.expect(Self.bridge, reply: Self.herdrError("workspace.create", code: "demo_unsupported", message: "raw"))
        let model = Self.model(host)
        model.folder = "~/ledger"

        #expect(await model.start() == nil)
        #expect(model.error == String(localized: "The Demo host can’t start new chats. Add your own host to try this."))
    }

    @Test("其他 herdr 錯誤保留原文")
    func otherHerdrErrorKeepsMessage() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/ledger"), reply: Self.listing("/Users/demo/ledger", []))
        await host.expect(Self.bridge, reply: Self.herdrError("workspace.create", code: "something", message: "herdr says no"))
        let model = Self.model(host)
        model.folder = "~/ledger"

        #expect(await model.start() == nil)
        #expect(model.error == "herdr says no")
    }

    @Test("從資料夾瀏覽挑的資料夾填進表單;瀏覽從表單目前的資料夾開始")
    func choosingFolderFillsForm() {
        let model = Self.model(FakeHost())
        model.folder = "~/ledger"

        #expect(model.makeFolderPicker().startPath == "~/ledger")
        model.choose("/Users/demo/notes")
        #expect(model.folder == "/Users/demo/notes")

        model.folder = ""
        #expect(model.makeFolderPicker().startPath == nil)
    }
}
