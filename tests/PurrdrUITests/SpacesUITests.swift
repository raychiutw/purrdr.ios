import XCTest

/// Spaces／Agents 兩種檢視(#40);Spaces 檢視每個「主機 · workspace」一段、列出 Tab(#275,原型 purrdr-screens 定案版)。
/// Demo 主機：`ledger`(w1)、`weather-app`(w2)各一個 Tab、一個 Agent;`notes`(w3)的 Tab 有 Codex 與 shell「npm run dev」兩個 pane。
final class SpacesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Spaces 檢視：每個 workspace 一段，標題是「主機 · workspace」,段內是 Tab 列;沒有 #103 的群組與狀態條。
    @MainActor
    func testSpacesShowsWorkspaceSectionsWithTabs() {
        let app = XCUIApplication.launchUITesting()
        app.switchListMode(to: "Spaces")
        let notes = app.element("spaces.section.demo/w3")
        XCTAssertTrue(app.reveal(notes), "沒有 notes 的段落")
        XCTAssertTrue(notes.label.contains("Demo · notes"), "段落標題不是「主機 · workspace」:\(notes.label)")
        let tab = app.element("spaces.tab.demo/w3:t1")
        XCTAssertTrue(tab.exists)
        XCTAssertTrue(tab.label.contains("Sync notes to Markdown"), "Tab 列名稱應是 Tab 裡的聊天標題:\(tab.label)")
        XCTAssertGreaterThan(tab.frame.minY, notes.frame.minY, "Tab 列不在段落標題下方")
        XCTAssertFalse(app.element("workspace.group.demo/w3").exists, "不該再有 workspace 群組")
    }

    /// 只有一個 pane 的 Tab:點了直接開那個聊天。
    @MainActor
    func testTabWithOnePaneOpensChat() {
        let app = XCUIApplication.launchUITesting()
        app.switchListMode(to: "Spaces")
        let tab = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(tab))
        tab.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10), "點 Tab 沒有開聊天")
    }

    /// 有多個 pane 的 Tab:點了開那個 Tab 的版面圖，終端機方塊開它的 Pane 終端機;長按是 workspace 的動作(#40 補充)。
    @MainActor
    func testTabWithSeveralPanesOpensLayout() {
        let app = XCUIApplication.launchUITesting()
        app.switchListMode(to: "Spaces")
        let tab = app.element("spaces.tab.demo/w3:t1")
        XCTAssertTrue(app.reveal(tab))

        tab.press(forDuration: 1.2)
        for title in ["Show Layout", "Rename Tab…", "Close Workspace…"] {
            XCTAssertTrue(app.buttons[title].waitUntilExists(timeout: 5), "長按選單沒有「\(title)」")
        }
        // 點螢幕下方的空白處關選單(列變高後選單位置會移動，點正中央可能點到選單項目)。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(app.buttons["Show Layout"].waitUntilGone(timeout: 5))

        tab.tap()
        let shellBlock = app.buttons["layout.block.w3:p2"]
        XCTAssertTrue(shellBlock.waitUntilExists(timeout: 5), "點 Tab 沒有開版面圖")
        shellBlock.tap()

        let status = app.element("terminal.status")
        XCTAssertTrue(status.waitUntilExists(timeout: 10), "點終端機方塊沒有開 Pane 終端機")
        XCTAssertTrue(status.label.contains("npm run dev"), "終端機標題不是程式名:\(status.label)")
    }

    /// 長按 Tab 列改的是那個 Tab;長按 Workspace 標題改 Workspace(#456)。
    @MainActor
    func testRenameTabAndWorkspaceFromSpaces() {
        let app = XCUIApplication.launchUITesting()
        app.switchListMode(to: "Spaces")
        let tab = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(tab))

        tab.press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["menu.renameWorkspace"].exists, "Tab 列的選單不該改 Workspace")
        app.buttons["menu.renameTab"].tap()
        let tabAlert = app.alerts["Rename Tab"]
        XCTAssertTrue(tabAlert.waitUntilExists(timeout: 5))
        XCTAssertEqual(tabAlert.textFields.firstMatch.value as? String, "1")
        tabAlert.textFields.firstMatch.typeEnglish(XCUIKeyboardKey.delete.rawValue + "tests")
        tabAlert.buttons["Rename"].tap()
        XCTAssertTrue(tabAlert.waitUntilGone(timeout: 5))
        // 這個 Tab 只有一個 Agent,列標題由內容決定;Workspace 標題沒變。
        XCTAssertTrue(app.element("spaces.section.demo/w1").label.contains("ledger"))

        let header = app.element("spaces.section.demo/w1")
        header.press(forDuration: 1.2)
        // 長按標題出現系統選單(不是直接開提示框)，再選「重新命名 Workspace…」才開。
        XCTAssertTrue(app.buttons["menu.renameWorkspace"].waitUntilExists(timeout: 5), "標題長按沒有出現選單:\(app.debugDescription)")
        for title in ["Show Layout", "New Worktree…", "Close Workspace…"] {
            XCTAssertTrue(app.buttons[title].waitUntilExists(timeout: 5), "標題長按選單沒有「\(title)」")
        }
        XCTAssertFalse(app.alerts["Rename Workspace"].exists, "選單還沒選就開了提示框")
        app.buttons["menu.renameWorkspace"].tap()
        let workspaceAlert = app.alerts["Rename Workspace"]
        XCTAssertTrue(workspaceAlert.waitUntilExists(timeout: 5))
        workspaceAlert.textFields.firstMatch.typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "Budget")
        workspaceAlert.buttons["Rename"].tap()
        XCTAssertTrue(workspaceAlert.waitUntilGone(timeout: 5))
        let renamed = NSPredicate(format: "label CONTAINS %@", "Budget")
        XCTAssertTrue(app.element("spaces.section.demo/w1").wait(for: renamed, timeout: 5), "Workspace 標題沒有更新")
    }

    /// 選 Agents 後每個 agent 一列，沒有群組與終端機列(#244)。
    @MainActor
    func testSwitchingToAgentsShowsOneRowPerAgent() {
        let app = XCUIApplication.launchUITesting()
        app.switchListMode(to: "Spaces")
        XCTAssertTrue(app.element("spaces.section.demo/w3").waitUntilExists(timeout: 10))
        XCTAssertEqual(app.listModeName, "Spaces")

        app.switchListMode(to: "Agents")

        XCTAssertTrue(app.element("spaces.section.demo/w3").waitUntilGone(timeout: 5), "Agents 檢視不該有 workspace 段落")
        XCTAssertTrue(app.element("agent.row.demo/w3:p1").waitUntilExists(timeout: 5))
        XCTAssertFalse(app.element("spaces.tab.demo/w3:t1").exists, "Agents 檢視不該有 Tab 列")
        XCTAssertFalse(app.element("agentList.section.needsYou").exists, "Agents 檢視是單一清單，不該有分段標題")
        XCTAssertEqual(app.listModeName, "Agents")
    }
}
