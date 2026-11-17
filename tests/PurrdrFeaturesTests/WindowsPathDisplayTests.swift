import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Windows 主機回報的路徑是 `C:\…`(#26):資料夾瀏覽切段、往上一層、組子資料夾路徑，以及列表副標的資料夾段，
/// 都依路徑語法(`HostPathSyntax`),不把 `C:\Users\demo` 當成一整段。
@MainActor
@Suite("Windows 主機的路徑顯示與瀏覽")
struct WindowsPathDisplayTests {
    static let home = """
        C:\\Users\\demo
        total 8
        drwxr-xr-x  3 0  0   96 Nov 16 05:12 ledger

        """

    static func listing(_ path: String) -> FakeReply {
        FakeReply(stdout: Data("\(path)\ntotal 0\n".utf8))
    }

    @Test("檔案瀏覽：標題是最後一段;打開子資料夾用反斜線組路徑;往上一層到磁碟機根目錄為止")
    func folderBrowser() async {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        await host.expect(HostFolderCommand.list(#"C:\Users\demo\ledger"#), reply: Self.listing(#"C:\Users\demo\ledger"#))
        await host.expect(HostFolderCommand.list(#"C:\Users\demo"#), reply: FakeReply(stdout: Data(Self.home.utf8)))
        await host.expect(HostFolderCommand.list(#"C:\Users"#), reply: Self.listing(#"C:\Users"#))
        await host.expect(HostFolderCommand.list(#"C:\"#), reply: Self.listing(#"C:\"#))
        let model = FolderBrowserModel(folders: HostFolders(channel: host), hostName: "PC")

        await model.load()
        #expect(model.title == "demo")
        await model.open(FolderEntry(name: "ledger", kind: .folder, size: 96))
        #expect(model.title == "ledger")
        await model.goUp()
        await model.goUp()
        #expect(model.title == "Users")
        await model.goUp()
        #expect(model.title == #"C:\"#)
        #expect(!model.canGoUp)
        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("新增對話的資料夾選擇：子資料夾與上一層都用 Windows 路徑")
    func folderPicker() async {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: ""), reply: FakeReply(stdout: NewChatFolders.output(path: #"C:\Users\demo"#, folders: ["ledger"])))
        await host.expect(
            NewChatFolders.command(for: #"C:\Users\demo\ledger"#),
            reply: FakeReply(stdout: NewChatFolders.output(path: #"C:\Users\demo\ledger"#, folders: [])))
        await host.expect(NewChatFolders.command(for: #"C:\Users\demo"#), reply: FakeReply(stdout: NewChatFolders.output(path: #"C:\Users\demo"#, folders: ["ledger"])))
        await host.expect(NewChatFolders.command(for: #"C:\Users"#), reply: FakeReply(stdout: NewChatFolders.output(path: #"C:\Users"#, folders: ["demo"])))
        await host.expect(NewChatFolders.command(for: #"C:\"#), reply: FakeReply(stdout: NewChatFolders.output(path: #"C:\"#, folders: ["Users"])))
        let picker = FolderPickerModel(folders: NewChatFolders(channel: host), start: nil)

        await picker.load()
        await picker.open("ledger")
        #expect(picker.chosenPath == #"C:\Users\demo\ledger"#)
        await picker.goUp()
        await picker.goUp()
        await picker.goUp()
        #expect(picker.chosenPath == #"C:\"#)
        #expect(!picker.canGoUp)
        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("列表副標的資料夾：Windows 路徑取最後兩段，以反斜線連接")
    func rowFolder() {
        let agent = Agent(
            paneID: "w1:p1", workspaceID: "w1", kind: "claude", status: .idle, cwd: #"C:\Users\demo\Projects\ledger"#)
        let subtitle = AgentRowText.subtitle(for: agent, title: "t", siblings: [agent])
        #expect(subtitle.hasSuffix(#" · Projects\ledger"#), "\(subtitle)")
        #expect(!subtitle.contains("Users"), "\(subtitle)")

        let pane = Pane(id: "w1:p2", workspaceID: "w1", tabID: "w1:t1", cwd: #"C:\Users\demo\Projects\ledger"#, label: "pwsh")
        #expect(TerminalRow(pane: pane, host: .demo, hostLabel: nil).subtitle == #"pwsh · Projects\ledger"#)
    }

    @Test("人取的 workspace 名稱：Windows 資料夾最後一段同名時不算，標題不重複顯示資料夾名")
    func humanLabelWithWindowsFolder() {
        let agent = Agent(
            paneID: "w1:p1", workspaceID: "w1", kind: "claude", status: .idle, workspaceLabel: "ledger",
            cwd: #"C:\Users\demo\Projects\ledger"#)
        #expect(AgentRowText.humanLabel("ledger", siblings: [agent]) == nil)
        #expect(AgentRowText.humanLabel("Ledger App", siblings: [agent]) == "Ledger App")
    }

    @Test("版面圖的終端機方塊：Windows 資料夾只顯示最後一段")
    func terminalBlockProgramWithWindowsFolder() {
        let pane = Pane(id: "w1:p2", workspaceID: "w1", tabID: "w1:t1", cwd: #"C:\Users\demo\Projects\ledger"#)
        let block = SpacesLayout.Block(
            id: "w1:p2", frame: .init(x: 0, y: 0, width: 1, height: 1), pane: pane, agent: nil, isFocused: false)
        #expect(block.content == .terminal(program: "ledger"))
    }

    @Test("POSIX 路徑照舊")
    func posixUnchanged() {
        let pane = Pane(id: "w1:p2", workspaceID: "w1", tabID: "w1:t1", cwd: "/Users/demo/Projects/ledger", label: "zsh")
        #expect(TerminalRow(pane: pane, host: .demo, hostLabel: nil).subtitle == "zsh · Projects/ledger")
    }
}
