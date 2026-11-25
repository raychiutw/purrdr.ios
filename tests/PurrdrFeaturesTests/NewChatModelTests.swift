import Foundation
import PurrdrAgentFeatures
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

    // MARK: - 離開前確認(#621)

    @Test("有未送出的輸入(資料夾、名稱、第一則訊息)才要在離開前確認;空白不算")
    func unsentInputNeedsConfirmation() {
        let model = Self.model(FakeHost())
        #expect(!model.hasUnsentInput)
        model.message = "   \n"
        #expect(!model.hasUnsentInput, "只有空白不算輸入")
        for edit: (NewChatModel) -> Void in [{ $0.folder = "~/app" }, { $0.workspaceName = "w" }, { $0.tabName = "t" }, { $0.message = "fix it" }] {
            let fresh = Self.model(FakeHost())
            edit(fresh)
            #expect(fresh.hasUnsentInput)
        }
    }

    @Test("資料夾瀏覽往下一層:子資料夾的路徑與家目錄沿用到下一層的 model")
    func pickerChildLevelKeepsHome() async throws {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: ""), reply: Self.listing("/Users/demo", ["ledger"]))
        await host.expect(NewChatFolders.command(for: "/Users/demo/ledger"), reply: Self.listing("/Users/demo/ledger", []))
        let picker = FolderPickerModel(folders: NewChatFolders(channel: host), start: nil)
        await picker.load()
        let childPath = try #require(picker.childPath("ledger"))
        #expect(childPath == "/Users/demo/ledger")

        let child = picker.child(at: childPath)
        #expect(child.startPath == "/Users/demo/ledger")
        await child.load()
        #expect(child.chosenPath == "/Users/demo/ledger")
        #expect(child.breadcrumbs.first?.title == "~", "下一層仍以家目錄為 ~ 起點")
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

    @Test("資料夾瀏覽的路徑麵包屑(比照檔案頁，實機回報 2026-11-20):家目錄以「~」開頭，點一段回到那一層")
    func pickerBreadcrumbs() async throws {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: ""), reply: Self.listing("/Users/demo", ["ledger", "notes"]))
        await host.expect(NewChatFolders.command(for: "/Users/demo/ledger"), reply: Self.listing("/Users/demo/ledger", ["reports"]))
        await host.expect(NewChatFolders.command(for: "/Users/demo"), reply: Self.listing("/Users/demo", ["ledger", "notes"]))
        let picker = FolderPickerModel(folders: NewChatFolders(channel: host), start: nil)

        await picker.load()
        await picker.open("ledger")
        #expect(picker.breadcrumbs.map(\.title) == ["~", "ledger"])
        #expect(picker.breadcrumbs.first?.isHome == true)

        await picker.go(to: try #require(picker.breadcrumbs.first))
        #expect(picker.chosenPath == "/Users/demo")
        #expect(await host.unmetExpectations.isEmpty)
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

    static let created = #"{"id":"purrdr:workspace.create","result":{"type":"workspace_created","workspace":{"workspace_id":"w4","number":4,"label":"ledger","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w4:t1","agent_status":"unknown"},"tab":{"tab_id":"w4:t1","workspace_id":"w4","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"w4:p1","terminal_id":"term_0009","workspace_id":"w4","tab_id":"w4:t1","focused":false,"agent_status":"unknown","revision":0}}}"#

    static func reply(_ json: String) -> FakeReply {
        FakeReply(stdout: Data(json.utf8) + [0x0A], trigger: .afterStdinLine)
    }

    @Test("預設 Claude Code(#272,原型):資料夾與第一則訊息都填了才能開始")
    func defaults() {
        let model = Self.model(FakeHost())

        #expect(model.agent == .claude)
        #expect(!model.canStart)
        model.folder = "~/ledger"
        #expect(!model.canStart, "沒有第一則訊息不能開始")
        model.message = "  "
        #expect(!model.canStart)
        model.message = "Fix the CSV quoting"
        #expect(model.canStart)
        model.folder = "  "
        #expect(!model.canStart, "沒有資料夾不能開始")
    }

    @Test("開始：建立 workspace(名稱由 herdr 用資料夾名)、以 agent 自己的權限設定啟動，就緒後送出第一則訊息")
    func startsAndSendsFirstMessage() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/ledger"), reply: Self.listing("/Users/demo/ledger", []))
        await host.expect(Self.bridge, reply: Self.reply(Self.created))
        await host.expect(Self.bridge, reply: Self.reply(#"{"id":"purrdr:agent.start","result":{"type":"agent_started","agent":{"pane_id":"w4:p1"},"argv":["claude"]}}"#))
        await host.expect(Self.bridge, reply: Self.reply(#"{"id":"purrdr:agent.prompt","result":{"type":"agent_prompted","delivery":"submitted"}}"#))
        let model = Self.model(host)
        model.folder = " ~/ledger "
        model.message = " Fix the CSV quoting "

        let workspace = await model.start()

        #expect(workspace == CreatedWorkspace(workspaceID: "w4", rootPaneID: "w4:p1"))
        #expect(model.error == nil)
        #expect(model.unsentMessage == nil)
        #expect(!model.isStarting)
        let executions = await host.executions
        #expect(!executions[1].stdinText.contains("label"))
        #expect(!executions[2].stdinText.contains("permission-mode"))
        #expect(executions[3].stdinText.contains(#""method":"agent.prompt""#))
        #expect(executions[3].stdinText.contains(#""text":"Fix the CSV quoting""#))
        #expect(executions[3].stdinText.contains(#""target":"w4:p1""#))
    }

    @Test("agent 停在啟動問題(例如資料夾信任):不送第一則訊息，留給聊天的輸入框")
    func keepsMessageWhenAgentNotReady() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/ledger"), reply: Self.listing("/Users/demo/ledger", []))
        await host.expect(Self.bridge, reply: Self.reply(Self.created))
        await host.expect(Self.bridge, reply: Self.herdrError("agent.start", code: "agent_not_ready", message: "trust prompt"))
        let model = Self.model(host)
        model.folder = "~/ledger"
        model.message = "Fix the CSV quoting"

        let workspace = await model.start()

        #expect(workspace == CreatedWorkspace(workspaceID: "w4", rootPaneID: "w4:p1"))
        #expect(model.unsentMessage == "Fix the CSV quoting")
        #expect(await host.executions.count == 3, "不該送 agent.prompt")
    }

    @Test("沒送出的第一則訊息放進新聊天的輸入框(草稿)")
    func unsentMessageBecomesDraft() {
        let hosts = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: { _, _, _ in FakeHost() })
        let route = ChatRoute(host: .demo, paneID: "w4:p1")

        hosts.member(for: route.host).keepDraft("Fix the CSV quoting", paneID: route.paneID)

        #expect(hosts.member(for: route.host).conversation(route, sessionID: nil).draft == "Fix the CSV quoting")
    }

    @Test("名稱欄位:填了的 workspace 與 tab 名稱(去頭尾空白)交給主機;留空時不帶")
    func namesAreOptional() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/ledger"), reply: Self.listing("/Users/demo/ledger", []))
        await host.expect(Self.bridge, reply: Self.reply(Self.created))
        await host.expect(Self.bridge, reply: Self.reply(#"{"id":"purrdr:tab.rename","result":{"type":"ok"}}"#))
        await host.expect(Self.bridge, reply: Self.reply(#"{"id":"purrdr:agent.start","result":{"type":"agent_started","agent":{"pane_id":"w4:p1"},"argv":["claude"]}}"#))
        let model = Self.model(host)
        model.folder = "~/ledger"
        model.message = "Hi"
        model.workspaceName = "  Tax  "
        model.tabName = " Draft "
        _ = await model.start()
        let sent = await host.executions.map(\.stdinText)
        #expect(sent.contains { $0.contains(#""label":"Tax""#) && $0.contains("workspace.create") })
        #expect(sent.contains { $0.contains(#""label":"Draft""#) && $0.contains("tab.rename") })

        let plain = FakeHost()
        await plain.expect(NewChatFolders.command(for: "~/ledger"), reply: Self.listing("/Users/demo/ledger", []))
        await plain.expect(Self.bridge, reply: Self.reply(Self.created))
        await plain.expect(Self.bridge, reply: Self.reply(#"{"id":"purrdr:agent.start","result":{"type":"agent_started","agent":{"pane_id":"w4:p1"},"argv":["claude"]}}"#))
        let blank = Self.model(plain)
        blank.folder = "~/ledger"
        blank.message = "Hi"
        blank.workspaceName = "   "
        _ = await blank.start()
        let blankSent = await plain.executions.map(\.stdinText)
        #expect(!blankSent.contains { $0.contains("tab.rename") || $0.contains(#""label""#) })
    }

    @Test("主機上沒有這個資料夾：說明並建議用資料夾瀏覽")
    func missingFolderMessage() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/nope"), reply: FakeReply(exitCode: 66))
        let model = Self.model(host)
        model.folder = "~/nope"

        model.message = "Fix the CSV quoting"
        #expect(await model.start() == nil)
        #expect(model.error == String(localized: "There’s no such folder on the host. Check the location, or choose a folder on the host."))
    }

    @Test("Demo 主機拒絕建立 workspace:說明要用自己的主機(翻譯過的文字，不是 herdr 原文)")
    func demoRejection() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~/ledger"), reply: Self.listing("/Users/demo/ledger", []))
        await host.expect(Self.bridge, reply: Self.herdrError("workspace.create", code: "demo_unsupported", message: "raw"))
        let model = Self.model(host)
        model.folder = "~/ledger"

        model.message = "Fix the CSV quoting"
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

        model.message = "Fix the CSV quoting"
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
