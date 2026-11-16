import XCTest

/// 列的滑動、context menu 與 workspace 操作(行為規格 F2.7、F3.4、F3.5、F4),走 Demo 主機。
final class WorkspaceActionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func row(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["agent.row.demo/\(paneID)"].firstMatch
    }

    /// 往左滑「Workspace」→ 預填 workspace 名稱的表單 → 儲存後列表以新名稱重讀。
    @MainActor
    func testRenameWorkspaceFromSwipe() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))

        ledger.swipeLeft()
        app.buttons["Workspace"].firstMatch.tap()

        let field = app.textFields["workspace.rename.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "沒有重新命名表單")
        XCTAssertEqual(field.value as? String, "ledger", "沒有預填 workspace 名稱")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "Budget")
        app.buttons["Save"].tap()

        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "儲存後表單沒有關閉")
        let renamed = NSPredicate(format: "label CONTAINS %@", "Budget")
        expectation(for: renamed, evaluatedWith: row("w1:p1", in: app))
        waitForExpectations(timeout: 5)
    }

    /// 關閉是破壞性動作：先確認，確認後列消失。
    @MainActor
    func testCloseWorkspaceAsksFirst() {
        let app = XCUIApplication.launchUITesting()
        let weather = row("w2:p1", in: app)
        XCTAssertTrue(weather.waitForExistence(timeout: 10))

        weather.swipeLeft()
        app.buttons["Close"].firstMatch.tap()

        let confirm = app.buttons["Close Workspace"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "沒有先確認就關閉")
        XCTAssertTrue(weather.exists, "確認前列就不見了")
        confirm.tap()

        XCTAssertTrue(row("w2:p1", in: app).waitForNonExistence(timeout: 5), "關閉後列仍在")
        XCTAssertTrue(row("w1:p1", in: app).exists)
    }

    /// 往右滑釘選、靜音;再滑一次看到的是「取消釘選」。
    @MainActor
    func testPinFromLeadingSwipe() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))

        ledger.swipeRight()
        XCTAssertTrue(app.buttons["Mute"].firstMatch.waitForExistence(timeout: 5), "往右滑沒有靜音")
        app.buttons["Pin"].firstMatch.tap()

        ledger.swipeRight()
        XCTAssertTrue(app.buttons["Unpin"].firstMatch.waitForExistence(timeout: 5), "釘選後沒有變成「取消釘選」")
    }

    /// context menu 的頂端動作與滑動相同，另外有版面圖;從版面圖點 pane 方塊會關閉 sheet。
    @MainActor
    func testContextMenuMatchesSwipeAndOpensLayout() {
        let app = XCUIApplication.launchUITesting()
        let notes = row("w3:p1", in: app)
        XCTAssertTrue(notes.waitForExistence(timeout: 10))

        notes.press(forDuration: 1.2)
        for title in ["Rename Workspace…", "Show Layout", "New Worktree…", "Close Workspace…"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), "context menu 沒有「\(title)」")
        }
        // Codex 這列沒有 session:不提供釘選、靜音。
        XCTAssertFalse(app.buttons["Pin"].exists)
        app.buttons["Show Layout"].tap()

        let agentBlock = app.buttons["layout.block.w3:p1"]
        let shellBlock = app.buttons["layout.block.w3:p2"]
        XCTAssertTrue(agentBlock.waitForExistence(timeout: 5), "版面圖沒有 agent 方塊")
        XCTAssertTrue(shellBlock.exists, "版面圖沒有 shell 方塊")
        XCTAssertTrue(agentBlock.label.contains("Codex"), "agent 方塊沒有念出 agent:\(agentBlock.label)")
        XCTAssertTrue(shellBlock.label.contains("npm run dev"), "shell 方塊沒有念出程式名:\(shellBlock.label)")
        XCTAssertLessThan(agentBlock.frame.minX, shellBlock.frame.minX, "左右切分的位置不對")

        shellBlock.tap()
        XCTAssertTrue(shellBlock.waitForNonExistence(timeout: 5), "點方塊後版面圖沒有關閉")
    }

    /// Demo 主機不建立 worktree:錯誤留在表單裡說明。
    @MainActor
    func testNewWorktreeOnDemoHostExplains() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))

        ledger.press(forDuration: 1.2)
        app.buttons["New Worktree…"].tap()
        let branch = app.textFields["workspace.worktree.branch"]
        XCTAssertTrue(branch.waitForExistence(timeout: 5))
        branch.typeText("try-sorting")
        app.buttons["Create"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["workspace.worktree.error"].waitForExistence(timeout: 5), "沒有顯示錯誤")
    }
}
