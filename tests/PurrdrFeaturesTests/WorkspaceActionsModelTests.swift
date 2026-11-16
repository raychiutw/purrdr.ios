import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 列的操作：釘選、靜音、重新命名與關閉 workspace、建立 worktree(行為規格 F2.7、F3.4、F3.5)。
@MainActor
@Suite("Workspace 操作")
struct WorkspaceActionsModelTests {
    static let bridge = HerdrCommand.bridge()

    /// 記錄「重讀列表」被呼叫幾次。
    @MainActor
    final class RefreshCounter {
        var count = 0
    }

    static func model(
        host: FakeHost, store: InMemoryChatPreferencesStore = InMemoryChatPreferencesStore(),
        now: Date = Date(timeIntervalSince1970: 1_000), counter: RefreshCounter = RefreshCounter()
    ) -> WorkspaceActionsModel {
        WorkspaceActionsModel(client: HerdrClient(channel: host), preferences: store, now: { now }, refresh: { counter.count += 1 })
    }

    static func errorReply(code: String, message: String) -> FakeReply {
        // envelope 形狀沿用錄製的 workspace_not_found。
        .recorded("error.workspace-not-found.ndjson") { $0["error"] = ["code": code, "message": message] }
    }

    // MARK: - 釘選、靜音

    @Test("釘選記下釘選時間並存在本機;再按一次取消釘選")
    func pinStoresPinTimeLocally() {
        let store = InMemoryChatPreferencesStore()
        let model = Self.model(host: FakeHost(), store: store, now: Date(timeIntervalSince1970: 42))

        model.togglePin(sessionID: "s1")

        #expect(model.isPinned(sessionID: "s1"))
        #expect(store.load().pinned == ["s1": Date(timeIntervalSince1970: 42)])
        // 下次開 app(新的 model、同一個本機存放處)仍是釘選的。
        #expect(Self.model(host: FakeHost(), store: store).isPinned(sessionID: "s1"))

        model.togglePin(sessionID: "s1")
        #expect(!model.isPinned(sessionID: "s1"))
        #expect(store.load().pinned.isEmpty)
    }

    @Test("靜音存在本機;再按一次取消靜音")
    func muteStoresLocally() {
        let store = InMemoryChatPreferencesStore()
        let model = Self.model(host: FakeHost(), store: store)

        model.toggleMute(sessionID: "s1")
        #expect(model.isMuted(sessionID: "s1"))
        #expect(store.load().muted == ["s1"])

        model.toggleMute(sessionID: "s1")
        #expect(!model.isMuted(sessionID: "s1"))
    }

    @Test("靜音改變時通知推播(改寫主機上的靜音清單,#29)")
    func muteChangeIsReported() {
        let model = Self.model(host: FakeHost(), store: InMemoryChatPreferencesStore())
        var reported: [Set<String>] = []
        model.mutedChanged = { reported.append($0) }

        model.toggleMute(sessionID: "s1")
        model.toggleMute(sessionID: "s1")

        #expect(reported == [["s1"], []])
    }

    // MARK: - 重新命名

    @Test("重新命名:修剪後非空且不同於原名稱才可儲存")
    func renameNeedsNewNonEmptyLabel() {
        #expect(WorkspaceActionsModel.canRename(from: "ledger", to: " Budget "))
        #expect(!WorkspaceActionsModel.canRename(from: "ledger", to: "   "))
        #expect(!WorkspaceActionsModel.canRename(from: "ledger", to: " ledger "))
    }

    @Test("重新命名成功：送修剪後的名稱，之後重讀列表")
    func renameSendsTrimmedLabelAndRefreshes() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("workspace.get.ndjson"))
        let counter = RefreshCounter()
        let model = Self.model(host: host, counter: counter)

        let renamed = await model.rename(workspaceID: "w1", to: "  Budget ")

        #expect(renamed)
        #expect(await host.executions.first?.stdinText.contains(#""params":{"label":"Budget","workspace_id":"w1"}"#) == true)
        #expect(counter.count == 1)
        #expect(model.renameError == nil)
    }

    @Test("重新命名失敗：保留 herdr 原文給表單顯示，不重讀")
    func renameFailureKeepsHerdrMessage() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("error.workspace-not-found.ndjson"))
        let counter = RefreshCounter()
        let model = Self.model(host: host, counter: counter)

        let renamed = await model.rename(workspaceID: "w99", to: "Budget")

        #expect(!renamed)
        #expect(model.renameError == "workspace w99 not found")
        #expect(counter.count == 0)
    }

    // MARK: - 關閉

    @Test("關閉成功：清掉這個 workspace 的聊天在本機的釘選與靜音，其他聊天不動，之後重讀列表")
    func closeClearsLocalPreferencesAndRefreshes() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: FakeReply(stdout: Data(#"{"id":"purrdr:workspace.close","result":{"type":"ok"}}"#.utf8 + [0x0A]), trigger: .afterStdinLine))
        let store = InMemoryChatPreferencesStore()
        let counter = RefreshCounter()
        let model = Self.model(host: host, store: store, counter: counter)
        model.togglePin(sessionID: "s1")
        model.toggleMute(sessionID: "s1")
        model.togglePin(sessionID: "other")

        await model.close(workspaceID: "w1", sessionIDs: ["s1", "s2"])

        #expect(await host.executions.first?.stdinText.contains(#""method":"workspace.close""#) == true)
        #expect(store.load().pinned.keys.sorted() == ["other"])
        #expect(store.load().muted.isEmpty)
        #expect(counter.count == 1)
        #expect(model.actionError == nil)
    }

    @Test("關閉被擋：同 repo 的 worktree 還開著時，告訴使用者先關它們(herdr 原文叫人加 --group,對手機無意義)")
    func closeGroupRequiredExplainsWhatToDo() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.errorReply(code: "workspace_group_close_required", message: "pass --group"))
        let store = InMemoryChatPreferencesStore()
        let model = Self.model(host: host, store: store)
        model.togglePin(sessionID: "s1")

        await model.close(workspaceID: "w1", sessionIDs: ["s1"])

        #expect(model.actionError == WorkspaceActionsModel.groupCloseRequiredMessage)
        #expect(store.load().pinned.keys.sorted() == ["s1"])
    }

    // MARK: - worktree

    @Test("建立 worktree 成功：回傳新 workspace,之後重讀列表")
    func createWorktreeRefreshes() async throws {
        let host = FakeHost()
        let reply = #"""
        {"id":"purrdr:worktree.create","result":{"type":"worktree_created",\#
        "workspace":{"workspace_id":"w3","number":3,"label":"garden-journal-try","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w3:t1","agent_status":"unknown"},\#
        "tab":{"tab_id":"w3:t1","workspace_id":"w3","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},\#
        "root_pane":{"pane_id":"w3:p1","terminal_id":"term_0001","workspace_id":"w3","tab_id":"w3:t1","focused":false,"agent_status":"unknown","revision":0},\#
        "worktree":{"path":"/Users/demo/.herdr/worktrees/garden-journal/try","branch":"try","is_bare":false,"is_detached":false,"is_prunable":false,"is_linked_worktree":true,"label":"garden-journal-try"}}}
        """#
        await host.expect(Self.bridge, reply: FakeReply(stdout: Data(reply.utf8) + [0x0A], trigger: .afterStdinLine))
        let counter = RefreshCounter()
        let model = Self.model(host: host, counter: counter)

        let created = await model.createWorktree(from: "w1", branch: " try ")

        #expect(created == CreatedWorkspace(workspaceID: "w3", rootPaneID: "w3:p1"))
        #expect(await host.executions.first?.stdinText.contains(#""branch":"try""#) == true)
        #expect(counter.count == 1)
    }

    @Test("建立 worktree:不在 git repo 時說明原因")
    func createWorktreeOutsideGitRepoExplains() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("error.not-git-worktree.ndjson"))
        let model = Self.model(host: host)

        let created = await model.createWorktree(from: "w2", branch: "try")

        #expect(created == nil)
        #expect(model.worktreeError == WorkspaceActionsModel.notGitRepoMessage)
    }
}
