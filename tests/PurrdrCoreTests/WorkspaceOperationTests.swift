import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Workspace 操作(行為規格 F3.4、F3.5,`herdr workspace --help`／`herdr worktree create --help` 與 `herdr api schema --json`)。
///
/// 重新命名、關閉、建立 worktree 會改主機狀態，不在作者主機上錄製：
/// 成功回應以唯讀的 `workspace.get` 錄製回應為底(同為 `workspace_info`),或依 schema 寫在測試裡;
/// 錯誤以唯讀指令錄到的同一個錯誤碼為準。
@Suite("Workspace 操作(經主機通道)")
struct WorkspaceOperationTests {
    static let bridge = HerdrCommand.bridge()

    /// schema 的 `ok` 回應(`workspace.close` 成功)。
    static let okReply = FakeReply(stdout: Data(#"{"id":"purrdr:workspace.close","result":{"type":"ok"}}"#.utf8 + [0x0A]), trigger: .afterStdinLine)

    @Test("重新命名 workspace:送 workspace.rename {workspace_id, label},不送 EOF,讀到回應後關閉通道")
    func renameSendsWorkspaceRename() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("workspace.get.ndjson") { response in
            var result = response["result"] as? [String: Any] ?? [:]
            var workspace = result["workspace"] as? [String: Any] ?? [:]
            workspace["label"] = "Budget"
            result["workspace"] = workspace
            response["result"] = result
        })

        try await HerdrClient(channel: host).renameWorkspace("w1", to: "Budget")

        let execution = try #require(await host.executions.first)
        #expect(execution.stdinText ==
            #"{"id":"purrdr:workspace.rename","method":"workspace.rename","params":{"label":"Budget","workspace_id":"w1"}}"# + "\n")
        #expect(execution.closedStdin == false)
        #expect(execution.closed == true)
    }

    @Test("重新命名 workspace:herdr 的錯誤碼與原文原樣丟出")
    func renameKeepsHerdrError() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("error.workspace-not-found.ndjson"))

        await #expect(throws: HerdrError.herdr(code: "workspace_not_found", message: "workspace w99 not found")) {
            try await HerdrClient(channel: host).renameWorkspace("w99", to: "Budget")
        }
    }

    @Test("關閉 workspace:送 workspace.close {workspace_id},不帶 close_group")
    func closeSendsWorkspaceClose() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.okReply)

        try await HerdrClient(channel: host).closeWorkspace("w2")

        #expect(await host.executions.first?.stdinText ==
            #"{"id":"purrdr:workspace.close","method":"workspace.close","params":{"workspace_id":"w2"}}"# + "\n")
    }

    @Test("關閉 workspace:同 repo 的 worktree workspace 還開著時，丟出 workspace_group_close_required")
    func closeReportsGroupCloseRequired() async {
        // 錯誤 envelope 形狀沿用錄製的 workspace_not_found;碼取自 herdr CLI 文件(cli-reference「Worktrees」)。
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("error.workspace-not-found.ndjson") {
            $0["error"] = ["code": "workspace_group_close_required", "message": "workspace has open linked worktrees; pass --group"]
        })

        await #expect(throws: HerdrError.herdr(code: "workspace_group_close_required", message: "workspace has open linked worktrees; pass --group")) {
            try await HerdrClient(channel: host).closeWorkspace("w1")
        }
    }

    @Test("建立 worktree:以 workspace 所在的 repo 為底，送 worktree.create {workspace_id, branch, focus:false},回傳新 workspace 與 root pane")
    func createWorktreeReturnsNewWorkspace() async throws {
        let host = FakeHost()
        // schema 的 `worktree_created`:workspace、tab、root_pane、worktree。
        let reply = #"""
        {"id":"purrdr:worktree.create","result":{"type":"worktree_created",\#
        "workspace":{"workspace_id":"w3","number":3,"label":"garden-journal-try-sorting","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w3:t1","agent_status":"unknown"},\#
        "tab":{"tab_id":"w3:t1","workspace_id":"w3","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},\#
        "root_pane":{"pane_id":"w3:p1","terminal_id":"term_0001","workspace_id":"w3","tab_id":"w3:t1","focused":false,"agent_status":"unknown","revision":0},\#
        "worktree":{"path":"/Users/demo/.herdr/worktrees/garden-journal/try-sorting","branch":"try-sorting","is_bare":false,"is_detached":false,"is_prunable":false,"is_linked_worktree":true,"label":"garden-journal-try-sorting"}}}
        """#
        await host.expect(Self.bridge, reply: FakeReply(stdout: Data(reply.utf8) + [0x0A], trigger: .afterStdinLine))

        let created = try await HerdrClient(channel: host).createWorktree(from: "w1", branch: "try-sorting")

        #expect(created == CreatedWorkspace(workspaceID: "w3", rootPaneID: "w3:p1"))
        #expect(await host.executions.first?.stdinText ==
            #"{"id":"purrdr:worktree.create","method":"worktree.create","params":{"branch":"try-sorting","focus":false,"workspace_id":"w1"}}"# + "\n")
    }

    @Test("建立 worktree:資料夾不在 git repo 時丟出 not_git_worktree")
    func createWorktreeOutsideGitRepo() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("error.not-git-worktree.ndjson"))

        await #expect(throws: HerdrError.herdr(code: "not_git_worktree", message: "Herdr worktree actions require a path inside a Git work tree")) {
            try await HerdrClient(channel: host).createWorktree(from: "w2", branch: "try-sorting")
        }
    }
}
