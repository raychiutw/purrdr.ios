import XCTest

/// Spaces(#40、#501 起聊天只有 Spaces);每個「主機 · workspace」一段、列出 Tab(#275,原型 purrdr-screens 定案版)。
/// Demo 主機：`ledger`(w1)、`weather-app`(w2)各一個 Tab、一個 Agent;`notes`(w3)的 Tab 有 Codex 與 shell「npm run dev」兩個 pane。
final class SpacesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Spaces 檢視：每個 workspace 一段，標題是「主機 · workspace」,段內是 Tab 列;沒有 #103 的群組與狀態條。
    @MainActor
    func testSpacesShowsWorkspaceSectionsWithTabs() {
        let app = XCUIApplication.launchUITesting()
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
        let tab = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(tab))
        tab.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10), "點 Tab 沒有開聊天")
    }

    /// 有多個 pane 的 Tab:點了開那個 Tab 的版面圖，終端機方塊開它的 Pane 終端機;長按是 workspace 的動作(#40 補充)。
    @MainActor
    func testTabWithSeveralPanesOpensLayout() {
        let app = XCUIApplication.launchUITesting()
        let tab = app.element("spaces.tab.demo/w3:t1")
        XCTAssertTrue(app.reveal(tab))

        tab.press(forDuration: 1.2)
        for title in ["Show Layout", "Rename Tab…", "Close Tab…"] {
            XCTAssertTrue(app.buttons[title].waitUntilExists(timeout: 5), "長按選單沒有「\(title)」")
        }
        // Workspace 層級的動作只在段落標題(#536)。
        for title in ["New Worktree…", "Close Workspace…"] {
            XCTAssertFalse(app.buttons[title].exists, "Tab 長按選單不該有「\(title)」")
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

    /// 長按選單與左滑都能關閉 Tab,關之前先確認;Demo 每個 Workspace 只有一個 Tab,所以確認文字是「連 Workspace 一起關」(#534)。
    @MainActor
    func testCloseTabFromMenuAndSwipe() {
        let app = XCUIApplication.launchUITesting()
        let first = app.element("spaces.tab.demo/w2:t1")
        XCTAssertTrue(app.reveal(first))

        first.press(forDuration: 1.2)
        app.buttons["menu.closeTab"].tap()
        let confirm = app.buttons["closeTab.confirm"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "沒有出現確認")
        XCTAssertEqual(confirm.label, "Close Tab and Workspace")
        app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        XCTAssertTrue(first.exists, "取消後 Tab 不該消失")

        first.press(forDuration: 1.2)
        app.buttons["menu.closeTab"].tap()
        confirm.tap()
        XCTAssertTrue(first.waitUntilGone(timeout: 10), "從選單關閉後 Tab 還在")

        let second = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(second))
        second.swipeLeft()
        app.buttons["menu.closeTab"].tap()
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "左滑沒有出現確認")
        confirm.tap()
        XCTAssertTrue(second.waitUntilGone(timeout: 10), "左滑關閉後 Tab 還在")
    }

    /// 閃退回歸(0.52.1):關掉同時在「需要你」段落的 Tab,而同一個 Workspace 還有別的 Tab。
    /// 兩段的列識別碼曾經相同，需要你段落整段消失時 SwiftUI List 算錯列數而中止 app。
    @MainActor
    func testClosingNeedsYouTabKeepsAppRunning() {
        let app = XCUIApplication.launchUITesting()
        app.openNewChatSheet()
        let sheet = app.element("sheet.newChat")
        XCTAssertTrue(sheet.waitUntilExists(timeout: 10))
        let weather = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'weather-app'")).firstMatch
        XCTAssertTrue(weather.waitUntilExists(timeout: 10), "沒有 weather-app")
        weather.tap()
        let message = app.textViews["newChat.message"].exists ? app.textViews["newChat.message"] : app.textFields["newChat.message"]
        app.scrollIntoView(message, search: .down)
        message.tap()
        message.typeEnglish("Second tab")
        let start = app.buttons["newChat.start"]
        app.scrollIntoView(start, search: .down)
        start.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.reveal(app.element("spaces.tab.demo/w2:t2")), "沒有第二個 Tab")
        XCTAssertTrue(app.descendants(matching: .any)["needsYou.section"].firstMatch.waitUntilExists(timeout: 10), "沒有需要你段落")
        let first = app.element("spaces.tab.demo/w2:t1")
        XCTAssertTrue(app.reveal(first))
        first.swipeLeft()
        app.buttons["menu.closeTab"].tap()
        let confirm = app.buttons["closeTab.confirm"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5))
        confirm.tap()
        // 等列消失(或 app 閃退)就停,不用固定等待;閃退時 `app.state` 不再是前景,下面的斷言會失敗。
        _ = UITestWait.until(timeout: 10) { app.state != .runningForeground || !first.existsWithoutIdle }
        XCTAssertEqual(app.state, .runningForeground, "關掉需要你的 Tab 後 app 閃退了")
        XCTAssertFalse(first.existsWithoutIdle, "關閉後 Tab 還在")
        // 列表更新後 app 還要能回應(閃退時取不到畫面);頂列的帳號鈕在才算活著。
        XCTAssertTrue(app.element("toolbar.account").waitUntilExists(timeout: 5), "關掉 Tab 後畫面沒有回應")
        XCTAssertEqual(app.state, .runningForeground, "關掉需要你的 Tab 後 app 閃退了")
    }

    /// 長按 Tab 列改的是那個 Tab;長按 Workspace 標題改 Workspace(#456)。
    @MainActor
    func testRenameTabAndWorkspaceFromSpaces() {
        let app = XCUIApplication.launchUITesting()
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

    /// 聊天只有 Spaces(#501):依 workspace 分段、每個 Tab 一列,沒有 Agents 檢視的單一清單與切換。
    @MainActor
    func testChatListIsSpacesOnly() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.element("spaces.section.demo/w3").waitUntilExists(timeout: 10))
        XCTAssertTrue(app.element("spaces.tab.demo/w3:t1").exists, "沒有 Tab 列")
        XCTAssertFalse(app.buttons["agentList.mode"].exists, "不該有 Agents／Spaces 切換")
        XCTAssertFalse(app.element("agentList.section.needsYou").exists, "不該有 Agents 檢視的分段標題")
    }
}
