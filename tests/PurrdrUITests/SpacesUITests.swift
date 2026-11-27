import XCTest

/// Spaces(#40、#501 起聊天只有 Spaces);每個「主機 · workspace」一段、列出 Tab(#275,原型 purrdr-screens 定案版)。
/// Demo 主機：`ledger`(w1)、`weather-app`(w2)各一個 Tab、一個 Agent;`notes`(w3)的 Tab 有 Codex 與 shell「npm run dev」兩個 pane。
final class SpacesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// Spaces 的整串操作(同一次啟動,原本 6 個測試合併;各段之間回到列表):
    /// 1. 多 pane 的 Tab 版面圖:長按選「Show Layout」、連續三次第一下點返回就返回、左緣滑動返回、點終端機方塊開 Pane 終端機;
    /// 2. 長按 Tab 改名、長按 Workspace 標題的選單:New Worktree 錯誤與改 Workspace 名稱(#456);
    /// 3. 閃退回歸(0.52.1):關掉同時在「需要你」段落的 Tab,而同一個 Workspace 還有別的 Tab;
    /// 4. 關閉是破壞性動作:Workspace 標題「Close Workspace…」與長按選單、左滑關閉 Tab 都先確認(#534);Demo 每個 Workspace 只有一個 Tab,
    ///    確認文字是「連 Workspace 一起關」(第 3 段後 weather-app 剩第二個 Tab,關它就是只剩一個 Tab 的情況)。
    @MainActor
    func testSpacesLayoutRenameWorktreeClosingNeedsYouTabAndCloseFromMenuAndSwipe() {
        let app = XCUIApplication.launchUITesting()

        step("版面圖與終端機方塊") {
            let tab = app.element("spaces.tab.demo/w3:t1")
            let shellBlock = app.buttons["layout.block.w3:p2"]
            XCTAssertTrue(app.reveal(tab))

            tab.press(forDuration: 1.2)
            for title in ["Show Layout", "Rename Tab…", "Close Tab…"] {
                XCTAssertTrue(app.buttons[title].waitUntilExists(timeout: 5), "長按選單沒有「\(title)」")
            }
            // Workspace 層級的動作只在段落標題(#536)。
            for title in ["New Worktree…", "Close Workspace…"] {
                XCTAssertFalse(app.buttons[title].exists, "Tab 長按選單不該有「\(title)」")
            }
            // 直接點選單的「Show Layout」(同時驗了這個項目,不靠點座標收選單)。
            app.buttons["Show Layout"].tap()
            XCTAssertTrue(shellBlock.waitUntilExists(timeout: 5), "選「Show Layout」沒有開版面圖")
            // 列尾 > 是 push(#619):左上返回、tab bar 保留;返回後回到列表,再點 Tab 進去。
            XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).exists, "版面圖左上沒有返回鈕")
            XCTAssertTrue(app.tabBars.firstMatch.exists, "版面圖沒有保留 tab bar")
            XCTAssertTrue(app.element("layout.page").waitUntilExistsAndSettled(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(shellBlock.waitUntilGone(timeout: 3), "第 1 輪第一下點返回沒有返回")

            for round in 2...3 {
                XCTAssertTrue(app.reveal(tab), "第 \(round) 輪找不到 Tab 列")
                tab.tap()
                XCTAssertTrue(app.element("layout.page").waitUntilExistsAndSettled(timeout: 5), "第 \(round) 輪沒有開版面圖")
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(shellBlock.waitUntilGone(timeout: 3), "第 \(round) 輪第一下點返回沒有返回")
            }
            XCTAssertTrue(app.reveal(tab))
            tab.tap()
            XCTAssertTrue(app.element("layout.page").waitUntilExistsAndSettled(timeout: 5))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
            XCTAssertTrue(shellBlock.waitUntilGone(timeout: 3), "左緣滑動沒有返回")

            XCTAssertTrue(app.reveal(tab))
            tab.tap()
            XCTAssertTrue(shellBlock.waitUntilExists(timeout: 5), "再點 Tab 沒有開版面圖")
            shellBlock.tap()

            XCTAssertTrue(app.waitForTerminalHeader(containing: "npm run dev", timeout: 10), "點終端機方塊沒有開 Pane 終端機,或標題不是程式名:\(app.terminalHeader)")
        }
        // 從終端機退回列表。
        for _ in 0..<3 where !app.element("spaces.tab.demo/w1:t1").isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = app.element("spaces.tab.demo/w1:t1").waitUntilHittable(timeout: 2)
        }

        step("改名與 New Worktree") {
            let tab = app.element("spaces.tab.demo/w1:t1")
            XCTAssertTrue(app.reveal(tab))

            tab.press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["menu.renameTab"].waitUntilExists(timeout: 5), "Tab 列沒有跳出選單")
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

            // Demo 主機不建立 worktree:錯誤留在表單裡說明(關掉 sheet 後再改名)。
            app.buttons["New Worktree…"].tap()
            let branch = app.textFields["workspace.worktree.branch"]
            XCTAssertTrue(branch.waitUntilExists(timeout: 5))
            app.assertModalToolbar(close: "sheet.close", confirm: "workspace.worktree.create")
            XCTAssertFalse(app.buttons["workspace.worktree.create"].isEnabled, "沒有分支名稱時 ✓ 應停用")
            branch.typeEnglish("try-sorting")
            app.buttons["workspace.worktree.create"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["workspace.worktree.error"].waitUntilExists(timeout: 5), "沒有顯示錯誤")
            app.buttons["sheet.close"].tap()
            XCTAssertTrue(branch.waitUntilGone(timeout: 5), "關閉後 worktree 表單還在")

            header.press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["menu.renameWorkspace"].waitUntilExists(timeout: 5), "標題再次長按沒有出現選單")
            app.buttons["menu.renameWorkspace"].tap()
            let workspaceAlert = app.alerts["Rename Workspace"]
            XCTAssertTrue(workspaceAlert.waitUntilExists(timeout: 5))
            workspaceAlert.textFields.firstMatch.typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "Budget")
            workspaceAlert.buttons["Rename"].tap()
            XCTAssertTrue(workspaceAlert.waitUntilGone(timeout: 5))
            let renamed = NSPredicate(format: "label CONTAINS %@", "Budget")
            XCTAssertTrue(app.element("spaces.section.demo/w1").wait(for: renamed, timeout: 5), "Workspace 標題沒有更新")
        }

        step("關掉需要你的 Tab 不閃退") {
            app.openNewChat()
            let sheet = app.element("newChat.page")
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
            XCTAssertTrue(sheet.waitUntilGone(timeout: 15))
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

        step("關閉 Workspace 與 Tab") {
            let notes = app.element("spaces.tab.demo/w3:t1")
            XCTAssertTrue(app.reveal(notes))
            // Workspace 的關閉只在段落標題的長按選單(#536)。
            let notesHeader = app.element("spaces.section.demo/w3")
            XCTAssertTrue(app.reveal(notesHeader))
            notesHeader.press(forDuration: 1.2)
            app.buttons["Close Workspace…"].firstMatch.tap()
            let closeWorkspace = app.buttons["Close Workspace"]
            XCTAssertTrue(closeWorkspace.waitUntilExists(timeout: 5), "沒有先確認就關閉")
            XCTAssertTrue(notes.exists, "確認前列就不見了")
            closeWorkspace.tap()
            XCTAssertTrue(notes.waitUntilGone(timeout: 5), "關閉 Workspace 後列仍在")

            let first = app.element("spaces.tab.demo/w2:t2")
            XCTAssertTrue(app.reveal(first))

            // 選單、確認與滑動動作都有出現動畫:每一步等「可點」再點,取消後等確認收乾淨才做下一步。
            let closeItem = app.buttons["menu.closeTab"].firstMatch
            first.press(forDuration: 1.2)
            XCTAssertTrue(closeItem.waitUntilHittable(timeout: 5), "長按沒有出現「關閉 Tab」")
            closeItem.tap()
            let confirm = app.buttons["closeTab.confirm"].firstMatch
            XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "沒有出現確認")
            XCTAssertEqual(confirm.label, "Close Tab and Workspace")
            app.otherElements["PopoverDismissRegion"].firstMatch.tap()
            XCTAssertTrue(confirm.waitUntilGone(timeout: 5), "取消後確認沒有收起")
            XCTAssertTrue(first.exists, "取消後 Tab 不該消失")

            first.press(forDuration: 1.2)
            XCTAssertTrue(closeItem.waitUntilHittable(timeout: 5), "第二次長按沒有出現「關閉 Tab」")
            closeItem.tap()
            XCTAssertTrue(confirm.waitUntilHittable(timeout: 5), "第二次沒有出現確認")
            confirm.tap()
            XCTAssertTrue(first.waitUntilGone(timeout: 10), "從選單關閉後 Tab 還在")

            let second = app.element("spaces.tab.demo/w1:t1")
            XCTAssertTrue(app.reveal(second))
            second.swipeLeft()
            XCTAssertTrue(closeItem.waitUntilHittable(timeout: 5), "左滑沒有出現「關閉 Tab」")
            closeItem.tap()
            XCTAssertTrue(confirm.waitUntilHittable(timeout: 5), "左滑沒有出現確認")
            confirm.tap()
            XCTAssertTrue(second.waitUntilGone(timeout: 10), "左滑關閉後 Tab 還在")
        }
    }
}
