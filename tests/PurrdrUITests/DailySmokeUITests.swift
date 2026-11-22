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
            let search = app.textFields["agentList.search"].firstMatch
            XCTAssertTrue(search.waitUntilExists(timeout: 5), "沒有搜尋欄")
            search.tap()
            search.typeEnglish("weather")
            XCTAssertTrue(app.element("agent.row.demo/w2:p1").waitUntilExists(timeout: 5))
            XCTAssertTrue(ledger.waitUntilGone(timeout: 5), "不符合的列仍在")
            search.typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "\n")
            XCTAssertTrue(ledger.waitUntilExists(timeout: 5), "清掉搜尋後列表沒有回來")
        }
        step("Spaces 檢視") {
            app.switchListMode(to: "Spaces")
            XCTAssertTrue(app.reveal(app.element("spaces.section.demo/w3")), "Spaces 沒有 workspace 段落")
            app.switchListMode(to: "Agents")
        }
        step("打開聊天並送出") {
            XCTAssertTrue(app.reveal(ledger))
            ledger.tap()
            let text = app.element("composer.text")
            XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
            text.tap()
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
        step("權限膠囊") {
            let capsule = app.element("composer.permissionMode")
            XCTAssertTrue(capsule.waitUntilExists(timeout: 10), "沒有權限模式膠囊")
            capsule.tap()
            let accept = app.buttons["Accept Edits"].firstMatch
            XCTAssertTrue(accept.waitUntilExists(timeout: 10), "sheet 裡沒有 Accept Edits")
            accept.tap()
            XCTAssertTrue(capsule.wait(for: NSPredicate(format: "value == 'Accept Edits'"), timeout: 10), "沒有切換成 Accept Edits")
        }
        step("變更頁") {
            let open = app.buttons["changes.open"].firstMatch
            XCTAssertTrue(open.waitUntilExists(timeout: 10), "對話標題列沒有變更鈕")
            open.tap()
            let summary = app.descendants(matching: .any)["changes.summary"].firstMatch
            XCTAssertTrue(summary.waitUntilExists(timeout: 10), "沒有變更清單")
            back(app)
        }
        step("終端機") {
            let open = app.buttons["terminal.open"].firstMatch
            XCTAssertTrue(open.waitUntilExists(timeout: 10), "對話標題列沒有終端機鈕")
            open.tap()
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

    /// 「⋯」選單:設定、新增聊天;帳號(未登入是登入頁)。
    @MainActor
    func testMenusAndSignedOutAccount() {
        let app = XCUIApplication.launchUITesting()

        step("設定") {
            app.openMoreMenuItem("menu.settings")
            XCTAssertTrue(app.element("sheet.settings").waitUntilExists(timeout: 10), "沒有開出設定")
            XCTAssertTrue(app.staticTexts["Automatic follows your device’s Light or Dark setting."].firstMatch.waitUntilExists(timeout: 5))
            app.buttons["sheet.done"].firstMatch.tapWhenReady()
            XCTAssertTrue(app.element("sheet.settings").waitUntilGone(timeout: 5), "設定沒有關閉")
        }
        step("新增聊天") {
            app.openMoreMenuItem("menu.newChat")
            XCTAssertTrue(app.element("sheet.newChat").waitUntilExists(timeout: 10), "沒有開出新增聊天")
            app.swipeDown(velocity: .fast)
            XCTAssertTrue(app.element("sheet.newChat").waitUntilGone(timeout: 5), "新增聊天沒有關閉")
        }
        step("未登入的帳號頁是登入頁") {
            app.openAccount()
            XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 10), "沒登入沒有直接顯示登入頁")
            XCTAssertTrue(app.buttons["member.signIn.apple"].exists, "沒有 Apple 登入鈕")
        }
    }

    /// Purrdr Plus 會員：帳號頁、通知、通知裝置。
    @MainActor
    func testPlusMemberAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        step("帳號頁與通知裝置") {
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
            app.openMoreMenuItem("menu.settings")
            let entry = app.buttons["settings.dataUsage"]
            app.scrollIntoView(entry, search: .down)
            entry.tapWhenReady()
            XCTAssertTrue(app.element("dataUsage.page").waitUntilExists(timeout: 10), "沒有數據用量頁")
            XCTAssertTrue(app.element("dataUsage.today").waitUntilExists(timeout: 5), "沒有今天的用量")
        }
    }

    /// 沒有電腦：空狀態的「新增主機」開引導，取消後試用 Demo。
    @MainActor
    func testNoHostsGuideAndDemo() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingNoHosts"])
        step("空狀態開新增主機引導") {
            XCTAssertTrue(app.descendants(matching: .any)["agentList.noHosts"].waitUntilExists(timeout: 10), "沒有沒有主機的空狀態")
            app.buttons["agentList.addHost"].tap()
            XCTAssertTrue(app.buttons["guide.option.ssh"].waitUntilExists(timeout: 5), "沒有開出新增主機引導")
            app.buttons["guide.cancel"].tapWhenReady()
            // 引導開在主機 sheet 裡：取消後若 sheet 還在就關掉，回到空狀態。
            let done = app.buttons["sheet.done"].firstMatch
            if done.waitUntilExists(timeout: 2) { done.tap() }
            XCTAssertTrue(app.descendants(matching: .any)["agentList.noHosts"].waitUntilExists(timeout: 5), "沒有回到空狀態")
        }
        step("試用 Demo") {
            app.buttons["agentList.tryDemo"].tapWhenReady()
            XCTAssertTrue(app.reveal(app.element("agent.row.demo/w1:p1")), "沒有列出 Demo 的 Agent")
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
