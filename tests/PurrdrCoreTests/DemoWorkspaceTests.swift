import Foundation
import PurrdrCore
import PurrdrDemo
import Testing

/// Demo 主機上的 workspace 操作與版面(行為規格 F3.1、F21):App Review 與 UI 測試看得到整條流程。
@Suite("Demo 主機的 workspace")
struct DemoWorkspaceTests {
    @Test("重新命名後，之後的 snapshot 用新名稱")
    func renameChangesLabel() async throws {
        let client = HerdrClient(channel: DemoHost())

        try await client.renameWorkspace("w1", to: "Budget")

        let snapshot = try await client.snapshot()
        #expect(snapshot.workspaces.first { $0.id == "w1" }?.label == "Budget")
        #expect(snapshot.agents.first { $0.paneID == "w1:p1" }?.workspaceLabel == "Budget")
    }

    @Test("重新命名 Tab 後，之後的 snapshot 用新名稱(#456)")
    func renameTabChangesLabel() async throws {
        let client = HerdrClient(channel: DemoHost())

        try await client.renameTab("w1:t1", to: "tests")

        let snapshot = try await client.snapshot()
        #expect(snapshot.tabs.first { $0.id == "w1:t1" }?.label == "tests")
        #expect(snapshot.tabs.first { $0.id == "w2:t1" }?.label == "1")
    }

    @Test("不存在的 Tab:tab_not_found(與 herdr 相同)")
    func unknownTab() async {
        await #expect(throws: HerdrError.herdr(code: "tab_not_found", message: "tab w9:t9 not found")) {
            try await HerdrClient(channel: DemoHost()).renameTab("w9:t9", to: "tests")
        }
    }

    @Test("關閉後，那個 workspace 的 tab、pane、版面與 Agent 都不見了")
    func closeRemovesWorkspace() async throws {
        let client = HerdrClient(channel: DemoHost())

        try await client.closeWorkspace("w2")

        let snapshot = try await client.snapshot()
        #expect(snapshot.workspaces.map(\.id) == ["w1", "w3"])
        #expect(!snapshot.agents.contains { $0.workspaceID == "w2" })
        #expect(!snapshot.panes.contains { $0.workspaceID == "w2" })
        #expect(!snapshot.tabs.contains { $0.workspaceID == "w2" })
        #expect(snapshot.layouts?.contains { $0.workspaceID == "w2" } == false)
    }

    @Test("不存在的 workspace:workspace_not_found(與 herdr 相同)")
    func unknownWorkspace() async {
        await #expect(throws: HerdrError.herdr(code: "workspace_not_found", message: "workspace w9 not found")) {
            try await HerdrClient(channel: DemoHost()).renameWorkspace("w9", to: "Budget")
        }
    }

    @Test("Demo 不建立 worktree,並說明要用自己的主機")
    func worktreeIsRefused() async {
        await #expect(throws: HerdrError.herdr(code: "demo_unsupported", message: DemoHost.unsupportedMessage)) {
            try await HerdrClient(channel: DemoHost()).createWorktree(from: "w1", branch: "try")
        }
    }

    @Test("有版面:notes 的 tab 左右切成 Codex 與一個 shell")
    func layoutsIncludeSplitWithShell() async throws {
        let snapshot = try await HerdrClient(channel: DemoHost()).snapshot()

        #expect(snapshot.layouts?.map(\.tabID) == ["w1:t1", "w2:t1", "w3:t1"])
        let notes = try #require(snapshot.layouts?.last)
        #expect(notes.panes.map(\.paneID) == ["w3:p1", "w3:p2"])
        #expect(snapshot.panes.first { $0.id == "w3:p2" }?.agentKind == nil)
        #expect(snapshot.panes.first { $0.id == "w3:p2" }?.terminalTitle == "npm run dev")
    }
}
