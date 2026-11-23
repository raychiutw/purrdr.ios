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

    /// 往左滑「Workspace」→ 預填 workspace 名稱的提示框 → 重新命名後列表以新名稱重讀。
    @MainActor
    func testRenameWorkspaceFromSwipe() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(ledger))

        ledger.swipeLeft()
        app.buttons["Workspace"].firstMatch.tap()

        let alert = app.alerts["Rename Workspace"]
        XCTAssertTrue(alert.waitUntilExists(timeout: 5), "沒有重新命名提示框")
        let field = alert.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "ledger", "沒有預填 workspace 名稱")
        XCTAssertFalse(alert.buttons["Rename"].isEnabled, "名稱沒改變時仍可按「重新命名」")
        field.typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "Budget")
        alert.buttons["Rename"].tap()

        XCTAssertTrue(alert.waitUntilGone(timeout: 5), "重新命名後提示框沒有關閉")
        let renamed = NSPredicate(format: "label CONTAINS %@", "Budget")
        XCTAssertTrue(row("w1:p1", in: app).wait(for: renamed, timeout: 5), "等待的條件沒有成立")
    }

    /// 長按列:「重新命名 Tab…」副標是目前名稱,排在「重新命名 Workspace…」之前;改完 Tab 名稱,再開選單看到新名稱(#456)。
    @MainActor
    func testRenameTabFromContextMenu() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(ledger))

        ledger.press(forDuration: 1.2)
        let renameTab = app.buttons["menu.renameTab"]
        let renameWorkspace = app.buttons["menu.renameWorkspace"]
        XCTAssertTrue(renameTab.waitUntilExists(timeout: 5), "選單沒有「重新命名 Tab…」")
        XCTAssertTrue(renameTab.label.contains("Current: 1"), "副標沒有目前名稱:\(renameTab.label)")
        XCTAssertTrue(renameWorkspace.label.contains("Current: ledger"), "副標沒有目前名稱:\(renameWorkspace.label)")
        XCTAssertLessThan(renameTab.frame.minY, renameWorkspace.frame.minY, "「重新命名 Tab…」要在「重新命名 Workspace…」之前")
        renameTab.tap()

        let alert = app.alerts["Rename Tab"]
        XCTAssertTrue(alert.waitUntilExists(timeout: 5), "沒有重新命名 Tab 的提示框")
        XCTAssertTrue(alert.staticTexts["The tab in “ledger”. herdr on the host will be renamed too."].exists, "沒有說明電腦上的 herdr 也會改")
        let field = alert.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "1", "沒有預填 Tab 名稱")
        XCTAssertFalse(alert.buttons["Rename"].isEnabled)
        field.typeEnglish(XCUIKeyboardKey.delete.rawValue + "tests")
        alert.buttons["Rename"].tap()
        XCTAssertTrue(alert.waitUntilGone(timeout: 5))

        // Workspace 名稱不變,Tab 名稱是新的。
        ledger.press(forDuration: 1.2)
        let again = app.buttons["menu.renameTab"]
        XCTAssertTrue(again.waitUntilExists(timeout: 5))
        XCTAssertTrue(again.label.contains("Current: tests"), "Tab 名稱沒有更新:\(again.label)")
        XCTAssertTrue(app.buttons["menu.renameWorkspace"].label.contains("Current: ledger"))
    }

    /// 關閉是破壞性動作：先確認，確認後列消失。
    @MainActor
    func testCloseWorkspaceAsksFirst() {
        let app = XCUIApplication.launchUITesting()
        let weather = row("w2:p1", in: app)
        XCTAssertTrue(weather.waitUntilExists(timeout: 10))

        weather.swipeLeft()
        app.buttons["Close"].firstMatch.tap()

        let confirm = app.buttons["Close Workspace"]
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "沒有先確認就關閉")
        XCTAssertTrue(weather.exists, "確認前列就不見了")
        confirm.tap()

        XCTAssertTrue(row("w2:p1", in: app).waitUntilGone(timeout: 5), "關閉後列仍在")
        XCTAssertTrue(row("w1:p1", in: app).exists)
    }

    /// 往右滑釘選、靜音;再滑一次看到的是「取消釘選」。
    @MainActor
    func testPinFromLeadingSwipe() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(ledger))

        ledger.swipeRight()
        XCTAssertTrue(app.buttons["Mute"].firstMatch.waitUntilExists(timeout: 5), "往右滑沒有靜音")
        app.buttons["Pin"].firstMatch.tap()

        // 釘選後列移到最上方的「已釘選」組;捲回頂端再滑。
        app.collectionViews.firstMatch.swipeDown()
        XCTAssertTrue(app.reveal(ledger))
        ledger.swipeRight()
        XCTAssertTrue(app.buttons["Unpin"].firstMatch.waitUntilExists(timeout: 5), "釘選後沒有變成「取消釘選」")
    }

    /// context menu 的頂端動作與滑動相同，另外有版面圖;從版面圖點 pane 方塊會關閉 sheet。
    @MainActor
    func testContextMenuMatchesSwipeAndOpensLayout() {
        let app = XCUIApplication.launchUITesting()
        let notes = row("w3:p1", in: app)
        XCTAssertTrue(notes.waitUntilExists(timeout: 10))

        notes.press(forDuration: 1.2)
        for title in ["Rename Tab…", "Rename Workspace…", "Show Layout", "New Worktree…", "Close Workspace…"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.waitUntilExists(timeout: 5), "context menu 沒有「\(title)」")
        }
        // Codex 這列沒有 session:不提供釘選、靜音。
        XCTAssertFalse(app.buttons["Pin"].exists)
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

        ledger.press(forDuration: 1.2)
        app.buttons["New Worktree…"].tap()
        let branch = app.textFields["workspace.worktree.branch"]
        XCTAssertTrue(branch.waitUntilExists(timeout: 5))
        branch.typeEnglish("try-sorting")
        app.buttons["Create"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["workspace.worktree.error"].waitUntilExists(timeout: 5), "沒有顯示錯誤")
    }
}
