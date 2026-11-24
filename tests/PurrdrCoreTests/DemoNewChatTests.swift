import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import Testing

/// Demo 主機上的新增對話(行為規格 F3.1、F21):資料夾瀏覽走得通，但開始時拒絕並說明要用自己的主機。
@Suite("Demo 主機的新增對話")
struct DemoNewChatTests {
    @Test("家目錄有三個專案資料夾;ledger/reports 是空的;不存在的資料夾是 notFound")
    func browsesDemoFolders() async throws {
        let folders = NewChatFolders(channel: DemoHost())

        #expect(try await folders.list(nil) == NewChatFolderListing(path: "/Users/demo", folders: ["ledger", "notes", "weather-app"]))
        #expect(try await folders.list("~/ledger") == NewChatFolderListing(path: "/Users/demo/ledger", folders: ["reports"]))
        #expect(try await folders.list("/Users/demo/ledger/reports/") == NewChatFolderListing(path: "/Users/demo/ledger/reports", folders: []))
        #expect(try await folders.list("/") == NewChatFolderListing(path: "/", folders: ["Users"]))
        await #expect(throws: NewChatFolderError.notFound("~/nope")) { try await folders.list("~/nope") }
    }

    @Test("新增對話的資料夾瀏覽與檔案瀏覽看到同一棵資料夾樹(同一份 Demo 資料)")
    func sameTreeAsFileBrowser() async throws {
        let host = DemoHost()
        let picker = NewChatFolders(channel: host)
        let files = HostFolders(channel: host)

        for path in ["/", "/Users", "/Users/demo", "/Users/demo/ledger", "/Users/demo/ledger/reports", "/Users/demo/notes"] {
            let listed = try await files.list(path).entries.filter { $0.kind == .folder }.map(\.name)
            #expect(try await picker.list(path).folders == listed, "\(path)")
        }
    }

    @Test("既有 Workspace 新增 Tab(#537):Demo 建出新 Tab 與 agent,快照多一個 Tab 與一個 Agent;agent 還在啟動所以第一則訊息留給輸入框")
    func newTabInExistingWorkspace() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        let launcher = NewChatLauncher(client: client, folders: NewChatFolders(channel: host))
        let before = try await client.snapshot()

        let started = try await launcher.start(NewChatRequest(
            folder: "/Users/demo/ledger", tabLabel: "Draft", agent: .claude, message: "hi", target: .existingWorkspace(id: "w1")))

        #expect(started == NewChatStarted(workspace: CreatedWorkspace(workspaceID: "w1", rootPaneID: "w1:p2"), sentMessage: false))
        let after = try await client.snapshot()
        #expect(after.tabs.count == before.tabs.count + 1)
        #expect(after.tabs.first { $0.id == "w1:t2" }?.label == "Draft")
        #expect(after.agents.contains { $0.paneID == "w1:p2" })
        #expect(after.agents.count == before.agents.count + 1)
    }

    @Test("既有 Workspace 不存在:Demo 回 workspace_not_found")
    func newTabInMissingWorkspace() async throws {
        let host = DemoHost()
        let launcher = NewChatLauncher(client: HerdrClient(channel: host), folders: NewChatFolders(channel: host))

        await #expect(throws: HerdrError.self) {
            try await launcher.start(NewChatRequest(folder: "/x", agent: .claude, target: .existingWorkspace(id: "w99")))
        }
    }

    @Test("開始：資料夾解析得到，但 workspace.create 回 demo_unsupported")
    func startIsRejected() async throws {
        let host = DemoHost()
        let launcher = NewChatLauncher(client: HerdrClient(channel: host), folders: NewChatFolders(channel: host))

        await #expect(throws: HerdrError.herdr(code: "demo_unsupported", message: DemoHost.unsupportedMessage)) {
            try await launcher.start(NewChatRequest(folder: "~/ledger", agent: .claude))
        }
    }
}
