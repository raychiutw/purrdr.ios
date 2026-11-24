import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 新增聊天選既有 Workspace(#537):清單取自主機快照,選了就在裡面新增 Tab。
@MainActor
@Suite("新增聊天:既有 Workspace")
struct NewChatExistingWorkspaceModelTests {
    static let bridge = HerdrCommand.bridge()

    static func model(_ host: FakeHost, supportsExistingWorkspaces: Bool = true) -> NewChatModel {
        NewChatModel(
            launcher: NewChatLauncher(client: HerdrClient(channel: host), folders: NewChatFolders(channel: host)),
            folders: NewChatFolders(channel: host), supportsExistingWorkspaces: supportsExistingWorkspaces)
    }

    static func loaded(_ host: FakeHost = FakeHost(), supportsExistingWorkspaces: Bool = true) async -> NewChatModel {
        await host.expect(bridge, reply: .recorded("session.snapshot.ndjson"))
        let model = Self.model(host, supportsExistingWorkspaces: supportsExistingWorkspaces)
        await model.loadWorkspaces()
        return model
    }

    static func reply(_ json: String) -> FakeReply {
        FakeReply(stdout: Data(json.utf8) + [0x0A], trigger: .afterStdinLine)
    }

    static let tabCreated = #"{"id":"purrdr:tab.create","result":{"type":"tab_created","tab":{"tab_id":"w1:t12","workspace_id":"w1","number":12,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"w1:p12","terminal_id":"term_0012","workspace_id":"w1","tab_id":"w1:t12","focused":false,"agent_status":"unknown","revision":0}}}"#
    static let agentStarted = #"{"id":"purrdr:agent.start","result":{"type":"agent_started","agent":{"pane_id":"w1:p12","workspace_id":"w1","kind":"claude","status":"idle"},"argv":["claude"]}}"#

    @Test("清單依 Workspace 順序列出名稱與資料夾(資料夾取第一個 Tab 的 pane 的工作目錄)")
    func listsWorkspaces() async {
        let model = await Self.loaded()

        #expect(model.workspaces == [
            ExistingWorkspace(id: "w1", name: "garden-journal", folder: "/Users/demo/Projects/garden-journal"),
            ExistingWorkspace(id: "w2", name: "scratch", folder: "/tmp/scratch"),
        ])
        #expect(model.canChooseExistingWorkspace)
        #expect(model.placement == .newWorkspace, "預設仍是新的 Workspace")
    }

    @Test("開啟前預選 Workspace:讀到清單後選好,不必填資料夾(#537)")
    func preselectBeforeLoad() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        let model = Self.model(host)
        model.preselectWorkspace("w2")
        await model.loadWorkspaces()

        #expect(model.placement == .existing("w2"))
        #expect(model.selectedWorkspace?.name == "scratch")
    }

    @Test("預選的 Workspace 已不在清單裡:維持新的 Workspace")
    func preselectBeforeLoadMissing() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        let model = Self.model(host)
        model.preselectWorkspace("w99")
        await model.loadWorkspaces()

        #expect(model.placement == .newWorkspace)
    }

    @Test("主機不支援(HTTPS 主機服務還沒有 tab.create)或沒有 Workspace:不提供既有 Workspace,也不讀快照")
    func unavailable() async {
        let host = FakeHost()
        let https = Self.model(host, supportsExistingWorkspaces: false)
        await https.loadWorkspaces()
        #expect(https.workspaces.isEmpty)
        #expect(!https.canChooseExistingWorkspace)
        #expect(await host.executions.isEmpty)
    }

    @Test("選了既有 Workspace:不必填資料夾,有第一則訊息就能開始;顯示它的資料夾")
    func existingNeedsNoFolder() async {
        let model = await Self.loaded()
        model.agent = .claude
        model.selectWorkspace("w1")

        #expect(model.folder.isEmpty)
        #expect(model.selectedWorkspace?.folder == "/Users/demo/Projects/garden-journal")
        #expect(!model.canStart, "還沒有第一則訊息")
        model.message = "Hi"
        #expect(model.canStart)
        model.placement = .newWorkspace
        #expect(!model.canStart, "回到新的 Workspace 又要填資料夾")
    }

    @Test("開始:tab.create(帶 Tab 名稱、不帶 Workspace 名稱與 cwd)後在新 Tab 啟動 agent、送第一則訊息")
    func startsInExistingWorkspace() async {
        let host = FakeHost()
        let model = await Self.loaded(host)
        await host.expect(Self.bridge, reply: Self.reply(Self.tabCreated))
        await host.expect(Self.bridge, reply: Self.reply(Self.agentStarted))
        await host.expect(Self.bridge, reply: Self.reply(#"{"id":"purrdr:agent.prompt","result":{"type":"agent_prompted"}}"#))
        model.selectWorkspace("w1")
        model.message = "Hi"
        model.workspaceName = "Ignored"
        model.tabName = " Draft "

        let created = await model.start()

        #expect(created == CreatedWorkspace(workspaceID: "w1", rootPaneID: "w1:p12"))
        let sent = await host.executions.map(\.stdinText)
        #expect(sent.count == 4)
        #expect(sent[1] == #"{"id":"purrdr:tab.create","method":"tab.create","params":{"focus":false,"label":"Draft","workspace_id":"w1"}}"# + "\n")
        #expect(sent[2].contains(#""pane_id":"w1:p12""#))
        #expect(sent[3].contains(#""target":"w1:p12""#))
        #expect(!sent.contains { $0.contains("Ignored") })
    }

    @Test("Workspace 在送出前被桌機關掉:說明原因、什麼都沒建,可以改選或改開新的")
    func workspaceGone() async {
        let host = FakeHost()
        let model = await Self.loaded(host)
        await host.expect(Self.bridge, reply: FakeReply(
            stdout: Data(#"{"id":"purrdr:tab.create","error":{"code":"workspace_not_found","message":"workspace w1 not found"}}"#.utf8) + [0x0A],
            trigger: .afterStdinLine))
        model.selectWorkspace("w1")
        model.message = "Hi"

        #expect(await model.start() == nil)

        #expect(model.error == String(localized: "That Workspace was closed on the host. Choose another one, or start a new Workspace."))
        model.placement = .newWorkspace
        #expect(model.placement == .newWorkspace)
    }

    @Test("預選的 Workspace 不在清單裡(已被關掉):維持新的 Workspace")
    func preselectMissing() async {
        let model = await Self.loaded()
        model.selectWorkspace("w9")
        #expect(model.placement == .newWorkspace)
        model.selectWorkspace("w2")
        #expect(model.placement == .existing("w2"))
    }
}
