import Testing

@testable import PurrdrFeatures

@Suite("Tab 與 Workspace 選單項目")
struct WorkspaceMenuEntriesTests {
    @Test("Tab 選單不含 Workspace 層級的新 worktree 與關閉 Workspace")
    func tabMenuHasNoWorkspaceEntries() {
        let entries = WorkspaceMenuLevel.tab(hasNewWindow: true, hasChats: true, hasTab: true).entries
        #expect(!entries.contains(.newWorktree))
        #expect(!entries.contains(.closeWorkspace))
        #expect(!entries.contains(.renameWorkspace))
    }

    @Test("Tab 選單保留新視窗、釘選、靜音、版面圖、重新命名 Tab、關閉 Tab")
    func tabMenuKeepsTabEntries() {
        let entries = WorkspaceMenuLevel.tab(hasNewWindow: true, hasChats: true, hasTab: true).entries
        #expect(entries == [.openInNewWindow, .pin, .mute, .showLayout, .renameTab, .closeTab])
    }

    @Test("沒有新視窗、聊天或 Tab 時對應項目不出現")
    func tabMenuOmitsUnavailable() {
        let entries = WorkspaceMenuLevel.tab(hasNewWindow: false, hasChats: false, hasTab: false).entries
        #expect(entries == [.showLayout])
    }

    @Test("Workspace 選單有改名、版面圖、新 worktree、關閉 Workspace,沒有 Tab 動作")
    func workspaceMenuEntries() {
        let entries = WorkspaceMenuLevel.workspace.entries
        #expect(entries == [.renameWorkspace, .showLayout, .newWorktree, .closeWorkspace])
    }
}
