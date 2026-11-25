import XCTest

/// 列的 context menu 與 workspace 操作(行為規格 F3.4、F3.5、F4),走 Demo 主機。#501 起聊天只有 Spaces:Agent 列的滑動動作(釘選、靜音、Workspace)隨 Agents 檢視移除。
final class WorkspaceActionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func row(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[chatRowID(paneID)].firstMatch
    }

    /// 關閉是破壞性動作：先確認，確認後列消失。
    @MainActor
    func testCloseWorkspaceAsksFirst() {
        let app = XCUIApplication.launchUITesting()
        let weather = row("w2:p1", in: app)
        XCTAssertTrue(weather.waitUntilExists(timeout: 10))

        // Workspace 的關閉只在段落標題的長按選單(#536)。
        let header = app.element("spaces.section.demo/w2")
        XCTAssertTrue(app.reveal(header))
        header.press(forDuration: 1.2)
        app.buttons["Close Workspace…"].firstMatch.tap()

        let confirm = app.buttons["Close Workspace"]
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "沒有先確認就關閉")
        XCTAssertTrue(weather.exists, "確認前列就不見了")
        confirm.tap()

        XCTAssertTrue(row("w2:p1", in: app).waitUntilGone(timeout: 5), "關閉後列仍在")
        XCTAssertTrue(row("w1:p1", in: app).exists)
    }

    /// context menu 有重新命名 Tab、版面圖、新 worktree、關閉(改 Tab 與 Workspace 名稱見 `SpacesUITests`);從版面圖點 pane 方塊會關閉 sheet。
    @MainActor
    func testContextMenuHasWorkspaceActionsAndOpensLayout() {
        let app = XCUIApplication.launchUITesting()
        let notes = row("w3:p1", in: app)
        XCTAssertTrue(notes.waitUntilExists(timeout: 10))

        notes.press(forDuration: 1.2)
        for title in ["Rename Tab…", "Show Layout", "Close Tab…"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.waitUntilExists(timeout: 5), "context menu 沒有「\(title)」")
        }
        for title in ["New Worktree…", "Close Workspace…"] {
            XCTAssertFalse(app.buttons[title].exists, "Tab 長按選單不該有「\(title)」")
        }
        app.buttons["Show Layout"].tap()

        let agentBlock = app.buttons["layout.block.w3:p1"]
        let shellBlock = app.buttons["layout.block.w3:p2"]
        XCTAssertTrue(agentBlock.waitUntilExists(timeout: 5), "版面圖沒有 agent 方塊")
        XCTAssertTrue(shellBlock.exists, "版面圖沒有 shell 方塊")
        XCTAssertTrue(agentBlock.label.contains("Codex"), "agent 方塊沒有念出 agent:\(agentBlock.label)")
        XCTAssertTrue(shellBlock.label.contains("npm run dev"), "shell 方塊沒有念出程式名:\(shellBlock.label)")
        XCTAssertLessThan(agentBlock.frame.minX, shellBlock.frame.minX, "左右切分的位置不對")

        shellBlock.tap()
        XCTAssertTrue(shellBlock.waitUntilGone(timeout: 5), "點方塊後版面圖沒有關閉")
    }

    /// Demo 主機不建立 worktree:錯誤留在表單裡說明。
    @MainActor
    func testNewWorktreeOnDemoHostExplains() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(ledger))

        let header = app.element("spaces.section.demo/w1")
        XCTAssertTrue(app.reveal(header))
        header.press(forDuration: 1.2)
        app.buttons["New Worktree…"].tap()
        let branch = app.textFields["workspace.worktree.branch"]
        XCTAssertTrue(branch.waitUntilExists(timeout: 5))
        app.assertModalToolbar(close: "sheet.close", confirm: "workspace.worktree.create")
        XCTAssertFalse(app.buttons["workspace.worktree.create"].isEnabled, "沒有分支名稱時 ✓ 應停用")
        branch.typeEnglish("try-sorting")
        app.buttons["workspace.worktree.create"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["workspace.worktree.error"].waitUntilExists(timeout: 5), "沒有顯示錯誤")
    }
}
