import XCTest

/// 日常組(#374、spec #367):每條使用者主流程一個煙霧檢查，串成幾條連續操作，每條只啟動一次 app。
/// 目標 5 分鐘內跑完；細節與分支在各功能自己的 UI 類別(完整組)與 model 測試。
/// 每一段以 `step` 標出名稱，失敗時看得出卡在哪一段；`continueAfterFailure = false`,一段失敗就停。
final class DailySmokeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// 列表 → 聊天(送出、slash、`!` 指令、權限膠囊)→ 變更頁 → 終端機。
    @MainActor
    func testListAndChat() {
        let app = XCUIApplication.launchUITesting()
        let ledger = app.element("agent.row.demo/w1:p1")

        step("列表看到 Demo 的 Agent") {
            XCTAssertTrue(app.reveal(ledger), "沒有看到 Demo 主機的 Agent")
            XCTAssertTrue(ledger.label.contains("ledger"), "列沒有 workspace 名稱:\(ledger.label)")
        }
        step("搜尋篩選列表") {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitUntilExists(timeout: 5), "沒有搜尋欄")
            search.tap()
            search.typeEnglish("weather")
            XCTAssertTrue(app.element("agent.row.demo/w2:p1").waitUntilExists(timeout: 5))
            XCTAssertTrue(ledger.waitUntilGone(timeout: 5), "不符合的列仍在")
            search.typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "\n")
            XCTAssertTrue(ledger.waitUntilExists(timeout: 5), "清掉搜尋後列表沒有回來")
            // 搜尋啟用時導覽列換成搜尋欄:取消後才看得到左上角的切換鈕。
            app.cancelSearchIfActive()
        }
        step("Spaces 檢視:一鍵切換、搜尋 workspace 與長按選單") {
            app.switchListMode(to: "Spaces")
            XCTAssertTrue(app.reveal(app.element("spaces.section.demo/w3")), "Spaces 沒有 workspace 段落")
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitUntilExists(timeout: 5), "Spaces 檢視沒有搜尋欄")
            search.tap()
            search.typeEnglish("weather")
            XCTAssertTrue(app.element("spaces.section.demo/w2").waitUntilExists(timeout: 5), "搜尋 workspace 名稱找不到 weather-app")
            XCTAssertTrue(app.element("spaces.section.demo/w3").waitUntilGone(timeout: 5), "不符合的 workspace 仍在")
            search.typeEnglish("zzz")
            XCTAssertTrue(app.element("agentList.noMatches").waitUntilExists(timeout: 5), "Spaces 搜尋不到時沒有說明")
            let clear = app.buttons["Clear text"].firstMatch
            XCTAssertTrue(clear.waitUntilExists(timeout: 5), "搜尋欄沒有清除鈕")
            clear.tap()
            XCTAssertTrue(app.element("spaces.section.demo/w3").waitUntilExists(timeout: 5), "清掉搜尋後 Spaces 沒有回來")
            app.cancelSearchIfActive()
            app.listModeControl.press(forDuration: 1.0)
            XCTAssertTrue(app.buttons["Agents"].firstMatch.waitUntilExists(timeout: 5), "長按切換鈕沒有出現選單")
            app.buttons["Agents"].firstMatch.tap()
            XCTAssertTrue(app.listModeControl.waitForLabel("View: Agents", timeout: 5), "從選單選 Agents 沒有切換")
        }
        step("打開聊天並送出") {
            XCTAssertTrue(app.reveal(ledger))
            ledger.tap()
            let text = app.element("composer.text")
            XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
            // 輸入列兩態(#382):收合一列沒有模型膠囊,聚焦展開後有。
            XCTAssertFalse(app.element("composer.model").exists, "收合時不該有模型膠囊")
            text.tap()
            XCTAssertTrue(app.element("composer.model").waitUntilExists(timeout: 5), "聚焦後輸入列沒有展開")
            text.typeEnglish("Add a header row too?")
            app.element("composer.send").tap()
            app.dismissKeyboard()
            let reply = app.descendants(matching: .any).matching(identifier: "conversation.agent")
                .matching(NSPredicate(format: "label CONTAINS 'This is the demo host'")).firstMatch
            XCTAssertTrue(reply.waitUntilExists(timeout: 15), "對話紀錄沒有接上 agent 的回覆")
        }
        step("slash 選單") {
            let text = app.element("composer.text")
            text.tap()
            text.typeEnglish("/")
            XCTAssertTrue(app.element("slash.menu").waitUntilExists(timeout: 10), "打 / 沒有出現選單")
            text.typeEnglish("check")
            let row = app.element("slash.row.demo-kit:check-diff")
            XCTAssertTrue(row.waitUntilExists(timeout: 5))
            row.tap()
            XCTAssertEqual(text.value as? String, "/demo-kit:check-diff ")
        }
        step("`!` 指令") {
            let text = app.element("composer.text")
            text.clearAndType("!ls Sources")
            XCTAssertTrue(app.element("composer.shellHint").waitUntilExists(timeout: 5), "沒有 shell 模式提示")
            app.element("composer.send").tap()
            XCTAssertTrue(app.element("conversation.shell").waitUntilExists(timeout: 15), "對話紀錄沒有接上 shell 區塊")
            app.dismissKeyboard()
        }
        step("標題面板與權限模式") {
            let header = app.element("conversation.header")
            XCTAssertTrue(header.waitUntilExists(timeout: 10), "沒有標題膠囊")
            header.tap()
            XCTAssertTrue(app.element("status.sheet").waitUntilExists(timeout: 5), "點標題沒有開出面板")
            // 面板上方是這個 Agent 的用量區(#389):範例主機還沒啟用用量顯示,有「啟用用量顯示」。
            XCTAssertTrue(app.element("usage.enable.claudeCode").waitUntilExists(timeout: 10), "面板沒有用量區的「啟用用量顯示」")
            XCTAssertTrue(app.element("progress.context").exists, "面板沒有 context 一列")
            let accept = app.buttons["Accept Edits"].firstMatch
            XCTAssertTrue(accept.waitUntilExists(timeout: 10), "面板裡沒有 Accept Edits")
            accept.tap()
            XCTAssertTrue(accept.wait(for: NSPredicate(format: "isSelected == true"), timeout: 10), "沒有切換成 Accept Edits")
            app.buttons["Done"].tap()
            XCTAssertTrue(app.element("status.sheet").waitUntilGone(timeout: 5), "面板沒有關閉")
        }
        step("變更頁") {
            app.conversationMoreItem("changes.open").tap()
            let summary = app.descendants(matching: .any)["changes.summary"].firstMatch
            XCTAssertTrue(summary.waitUntilExists(timeout: 10), "沒有變更清單")
            back(app)
        }
        step("終端機") {
            app.conversationMoreItem("terminal.open").tap()
            XCTAssertTrue(app.descendants(matching: .any)["terminal.screen"].firstMatch.waitUntilExists(timeout: 10), "沒有打開終端機")
        }
    }

    /// 「需要你」的聊天:subagent 卡、回答 Bash 權限。
    @MainActor
    func testNeedsYouAndSubagent() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w2:p1")

        step("subagent 卡展開") {
            XCTAssertTrue(app.staticTexts["Check how the widget refreshes"].waitUntilExists(timeout: 10), "沒有 subagent 卡")
            app.element("conversation.subagent").tap()
            XCTAssertTrue(app.element("conversation.subagent.result").waitUntilExists(timeout: 5), "點卡片沒有展開結果")
        }
        step("回答 Bash 權限") {
            let card = app.element("prompt.card")
            XCTAssertTrue(card.waitUntilExists(timeout: 10), "沒有提示卡")
            app.element("prompt.option.1").tap()
            XCTAssertTrue(app.element("prompt.answered").waitUntilExists(timeout: 10), "沒有顯示已回答")
        }
    }

    /// 5 個 tab(#390):設定、主機、檔案、流量各自是 tab;新增聊天在聊天 tab 右上;帳號(未登入是登入頁)四個以上的 tab 都有;
    /// 沒有「⋯」選單;對話隱藏 tab bar、返回後回來。
    @MainActor
    func testTabsAndSignedOutAccount() {
        let app = XCUIApplication.launchUITesting()

        step("沒有「⋯」選單,右上依 tab 不同") {
            XCTAssertTrue(app.buttons["toolbar.newChat"].firstMatch.waitUntilExists(timeout: 10), "聊天 tab 沒有新增聊天")
            XCTAssertFalse(app.buttons["toolbar.more"].exists, "不該再有「⋯」選單")
            app.openTab(.files)
            XCTAssertTrue(app.buttons["files.upload"].firstMatch.waitUntilExists(timeout: 10), "檔案 tab 沒有上傳")
            XCTAssertTrue(app.buttons["toolbar.account"].firstMatch.exists, "檔案 tab 沒有帳號鈕")
            XCTAssertFalse(app.buttons["toolbar.newChat"].exists, "檔案 tab 不該有新增聊天")
            app.openHostsTab()
            XCTAssertTrue(app.buttons["toolbar.account"].firstMatch.exists, "主機 tab 沒有帳號鈕")
            // 沒登入就沒有 Plus(#405):通知鎖定並寫出原因,不是可開關的列。
            let locked = app.buttons["hosts.tool.notifications.locked"].firstMatch
            XCTAssertTrue(locked.waitUntilExists(timeout: 10), "沒有 Plus 時主機 tab 的通知沒有鎖定")
            XCTAssertTrue((locked.value as? String)?.contains("Needs Purrdr Plus") == true, "鎖定的通知沒有說明需要 Purrdr Plus:\(String(describing: locked.value))")
            XCTAssertFalse(app.buttons["hosts.tool.notifications"].exists, "沒有 Plus 不該能進通知開關")
            XCTAssertTrue(app.element("usage.enable.claudeCode").waitUntilExists(timeout: 10), "主機 tab 的用量區沒有「啟用用量顯示」(#389)")
            XCTAssertTrue(app.element("usage.row.codex.fiveHour").waitUntilExists(timeout: 10), "主機 tab 的用量區沒有 Codex 5 小時")
            app.openTab(.traffic)
            XCTAssertTrue(app.element("dataUsage.page").waitUntilExists(timeout: 10), "流量 tab 沒有網路流量頁")
            XCTAssertTrue(app.buttons["toolbar.account"].firstMatch.exists, "流量 tab 沒有帳號鈕")
            XCTAssertFalse(app.buttons["hosts.add"].exists, "流量 tab 右上不放動作")
        }
        step("設定 tab 沒有「完成」,只有帳號鈕") {
            app.openSettingsTab()
            XCTAssertTrue(app.staticTexts["Automatic follows your device’s Light or Dark setting."].firstMatch.waitUntilExists(timeout: 5))
            XCTAssertFalse(app.buttons["sheet.done"].exists, "設定 tab 不是 sheet,不該有「完成」")
            XCTAssertTrue(app.buttons["Used"].firstMatch.exists, "設定 tab 沒有用量顯示的「已用」(#389)")
            XCTAssertTrue(app.buttons["toolbar.account"].firstMatch.exists, "設定 tab 沒有帳號鈕")
        }
        step("新增聊天") {
            app.openNewChatSheet()
            XCTAssertTrue(app.element("sheet.newChat").waitUntilExists(timeout: 10), "沒有開出新增聊天")
            app.swipeDown(velocity: .fast)
            XCTAssertTrue(app.element("sheet.newChat").waitUntilGone(timeout: 5), "新增聊天沒有關閉")
        }
        step("對話隱藏 tab bar,返回後回來") {
            app.openConversation(paneID: "w1:p1")
            XCTAssertTrue(app.tabBars.firstMatch.waitUntilGone(timeout: 5), "對話裡不該有 tab bar")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.tabBars.firstMatch.waitUntilExists(timeout: 5), "返回後 tab bar 沒有回來")
        }
        step("未登入的帳號頁是登入頁") {
            app.openAccount()
            XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 10), "沒登入沒有直接顯示登入頁")
            XCTAssertTrue(app.buttons["member.signIn.apple"].exists, "沒有 Apple 登入鈕")
        }
    }

    /// 兩個主機值(#390):在檔案 tab 換「選取中主機」不改聊天 tab 的「目前主機」篩選。
    @MainActor
    func testFilesHostMenuDoesNotChangeChatFilter() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnreachableHost"])
        app.filterHosts("Studio Mac")
        XCTAssertEqual(app.buttons["toolbar.currentHost"].firstMatch.label, "Showing: Studio Mac")

        app.openTab(.files)
        let picker = app.buttons["files.host"].firstMatch
        XCTAssertTrue(picker.waitUntilExists(timeout: 10), "檔案 tab 沒有主機選單")
        picker.tap()
        XCTAssertFalse(app.buttons["All Hosts"].exists, "檔案 tab 的主機選單不該列所有主機")
        XCTAssertTrue(app.buttons["hostMenu.addHost"].firstMatch.exists, "主機選單沒有新增主機…")
        app.buttons["Build Box"].firstMatch.tap()
        XCTAssertTrue(app.buttons["files.host"].firstMatch.waitForLabel(containing: "Build Box", timeout: 5))

        app.openTab(.chats)
        XCTAssertEqual(app.buttons["toolbar.currentHost"].firstMatch.label, "Showing: Studio Mac", "換選取中主機不該改聊天的目前主機")
    }

    /// 聊天 tab 的 badge 是「需要你」的 Agent 數。
    @MainActor
    func testChatsTabBadgeCountsNeedsYou() {
        let app = XCUIApplication.launchUITesting()
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chats")).firstMatch
        XCTAssertTrue(tab.waitUntilExists(timeout: 10))
        // badge 可能念在標籤尾端,也可能是元素的 value。
        let shows = UITestWait.until(timeout: 15) { tab.exists && (tab.label.contains("1") || (tab.value as? String)?.contains("1") == true) }
        XCTAssertTrue(shows, "聊天 tab 沒有標示 1 個需要你:\(tab.label) / \(String(describing: tab.value))")
    }

    /// Purrdr Plus 會員：帳號頁、通知、通知裝置。
    @MainActor
    func testPlusMemberAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        step("主機 tab 的通知有 Plus 時不鎖定,可進入開關頁") {
            app.openHostsTab()
            let row = app.buttons["hosts.tool.notifications"].firstMatch
            XCTAssertTrue(row.waitUntilExists(timeout: 10), "有 Plus 時主機 tab 沒有可進入的通知")
            XCTAssertFalse(app.buttons["hosts.tool.notifications.locked"].exists, "有 Plus 不該鎖定通知")
            row.tap()
            XCTAssertTrue(app.element("hosts.notifications").waitUntilExists(timeout: 10), "沒有進到通知開關頁")
        }
        step("帳號頁與通知裝置") {
            back(app)
            app.openAccountSheet()
            let device = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'account.pushDevice.' AND label CONTAINS 'Studio iPad'")).firstMatch
            XCTAssertTrue(app.scrollSheet("sheet.account", to: device, search: .down, timeout: 10), "帳號頁沒有通知裝置")
        }
    }

    /// 數據用量。
    @MainActor
    func testDataUsage() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedDataUsage"])
        step("數據用量摘要") {
            app.openTab(.traffic)
            XCTAssertTrue(app.element("dataUsage.page").waitUntilExists(timeout: 10), "沒有數據用量頁")
            XCTAssertTrue(app.element("dataUsage.today").waitUntilExists(timeout: 5), "沒有今天的用量")
        }
    }

    /// 沒有主機：空狀態的「新增主機」開引導，取消後體驗範例主機;可從主機 tab 移除,也可從新增主機引導再啟用(#394)。
    @MainActor
    func testNoHostsGuideAndDemo() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingNoHosts"])
        step("空狀態開新增主機引導") {
            XCTAssertTrue(app.descendants(matching: .any)["agentList.noHosts"].waitUntilExists(timeout: 10), "沒有沒有主機的空狀態")
            app.buttons["agentList.addHost"].tap()
            XCTAssertTrue(app.buttons["guide.option.ssh"].waitUntilExists(timeout: 5), "沒有開出新增主機引導")
            app.buttons["guide.cancel"].tapWhenReady()
            // 引導開在主機 tab 裡：取消後回到主機清單，再回聊天 tab 看到空狀態。
            XCTAssertTrue(app.buttons["hosts.add"].waitUntilExists(timeout: 5), "沒有回到主機清單")
            app.openTab(.chats)
            XCTAssertTrue(app.descendants(matching: .any)["agentList.noHosts"].waitUntilExists(timeout: 5), "沒有回到空狀態")
        }
        step("試用 Demo") {
            app.buttons["agentList.tryDemo"].tapWhenReady()
            XCTAssertTrue(app.reveal(app.element("agent.row.demo/w1:p1")), "沒有列出 Demo 的 Agent")
        }
        step("移除範例主機回到空狀態") {
            app.openTab(.hosts)
            app.buttons["hosts.demo.remove"].tapWhenReady()
            app.buttons["hosts.demo.remove.confirm"].firstMatch.tapWhenReady()
            XCTAssertFalse(app.buttons["hosts.demo"].waitForExistence(timeout: 2), "移除後範例主機還在主機清單")
            app.openTab(.chats)
            XCTAssertTrue(app.descendants(matching: .any)["agentList.noHosts"].waitUntilExists(timeout: 5), "移除後沒有回到空狀態")
        }
        step("新增主機引導第一頁可以體驗範例主機") {
            app.openTab(.hosts)
            app.buttons["hosts.add"].tapWhenReady()
            app.buttons["guide.tryDemo"].tapWhenReady()
            XCTAssertTrue(app.reveal(app.element("agent.row.demo/w1:p1")), "沒有列出範例主機的 Agent")
        }
    }

    /// 第一次開啟的歡迎頁。
    @MainActor
    func testWelcome() {
        let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"])
        step("歡迎頁試用 Demo") {
            XCTAssertTrue(app.descendants(matching: .any)["sheet.welcome"].waitUntilExists(timeout: 10), "沒有歡迎頁")
            app.buttons["welcome.demo"].tap()
            XCTAssertTrue(app.reveal(app.element("agent.row.demo/w1:p1")), "沒有回到列表")
        }
    }
}


extension XCUIApplication {
    /// 搜尋啟用時導覽列換成搜尋欄與取消:取消後才看得到左上角的切換鈕(已經收起就不動)。
    @MainActor
    func cancelSearchIfActive() {
        guard !listModeControl.isHittable else { return }
        let cancel = navigationBars.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'Close', 'Dismiss'}")).firstMatch
        if cancel.waitUntilExists(timeout: 5) {
            cancel.tap()
        } else {
            print("SEARCH-CANCEL-MISSING", navigationBars.firstMatch.debugDescription)
        }
        _ = listModeControl.waitUntilExists(timeout: 5)
    }
}
