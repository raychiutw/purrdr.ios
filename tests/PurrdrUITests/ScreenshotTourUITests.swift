import XCTest

/// 截圖巡覽(#34):以 Demo 主機逐一打開主要畫面並存截圖(XCTAttachment,永久保留)。
///
/// `scripts/screenshots.sh` 只跑這個類別，再從 result bundle 匯出截圖;完整 UI 套件也會跑它，
/// 所以它同時是「Demo 演得出每個主要功能」的煙霧測試。每張圖一個測試，彼此獨立，其中一張壞了不影響其他張。
/// 截圖名稱的數字是 App Store 截圖的建議順序;`design-*` 是設計稿比對用(淺色／深色)。
final class ScreenshotTourUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        // 用整個螢幕的截圖:`app.screenshot()` 要先取 app 的 accessibility 快照，聊天在輪詢、畫面一直更新時會逾時。
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 打開某個 Demo Agent 的聊天，回傳輸入框。
    @MainActor
    private func openChat(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.element("agent.row.demo/\(paneID)")
        XCTAssertTrue(app.reveal(row), "列表上沒有 \(paneID)")
        row.tap()
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
        return text
    }

    @MainActor
    func test01AgentListSpaces() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.element("agent.row.demo/w2:p1").waitUntilExists(timeout: 10))
        // Spaces 檢視(#275):每個「主機 · workspace」一段，列出 Tab。
        app.switchListMode(to: "Spaces")
        XCTAssertTrue(app.element("spaces.section.demo/w3").waitUntilExists(timeout: 10), "沒有 workspace 段落")
        capture("01-agent-list", app)
    }

    @MainActor
    func test02NeedsYouAnswer() {
        let app = XCUIApplication.launchUITesting()
        _ = openChat("w2:p1", in: app)
        XCTAssertTrue(app.staticTexts["Do you want to proceed?"].waitUntilExists(timeout: 15), "沒有「需要你」的提問")
        capture("02-needs-you", app)
    }

    @MainActor
    func test03ConversationWithSubagent() {
        let app = XCUIApplication.launchUITesting()
        _ = openChat("w2:p1", in: app)
        let card = app.staticTexts["Check how the widget refreshes"]
        XCTAssertTrue(card.waitUntilExists(timeout: 10), "沒有 subagent 卡")
        // 讓 subagent 卡在畫面中間。
        for _ in 0..<4 where !card.isHittable { app.swipeDown() }
        capture("03-subagent", app)
    }

    @MainActor
    func test04SlashMenu() {
        let app = XCUIApplication.launchUITesting()
        let text = openChat("w1:p1", in: app)
        text.tap()
        text.typeEnglish("/")
        XCTAssertTrue(app.element("slash.row.demo-kit:changelog").waitUntilExists(timeout: 10), "沒有 slash 選單")
        capture("04-slash-menu", app)
    }

    @MainActor
    func test05ModelPanelCard() {
        let app = XCUIApplication.launchUITesting()
        let text = openChat("w1:p1", in: app)
        text.tap()
        text.typeEnglish("/model")
        app.element("slash.row.model").tap()
        app.element("composer.send").tap()
        XCTAssertTrue(app.element("panel.card").waitUntilExists(timeout: 10), "沒有 /model 面板卡片")
        // 送出就收起鍵盤(#329);還聚焦才點。
        app.dismissKeyboard()
        capture("05-model-panel", app)
    }

    @MainActor
    func test06EffortPanelCard() {
        let app = XCUIApplication.launchUITesting()
        let text = openChat("w1:p1", in: app)
        text.tap()
        text.typeEnglish("/effort")
        app.element("slash.row.effort").tap()
        app.element("composer.send").tap()
        XCTAssertTrue(app.element("panel.levels").waitUntilExists(timeout: 10), "沒有 /effort 面板卡片")
        // 送出就收起鍵盤(#329);還聚焦才點。
        app.dismissKeyboard()
        capture("06-effort-panel", app)
    }

    @MainActor
    func test07ShellCommand() {
        let app = XCUIApplication.launchUITesting()
        let text = openChat("w1:p1", in: app)
        text.tap()
        text.typeEnglish("!git status")
        app.element("composer.send").tap()
        XCTAssertTrue(app.element("conversation.shell").waitUntilExists(timeout: 15), "沒有 shell 區塊")
        // 送出就收起鍵盤(#329);還聚焦才點。
        app.dismissKeyboard()
        capture("07-shell-command", app)
    }

    @MainActor
    func test08Terminal() {
        let app = XCUIApplication.launchUITesting()
        _ = openChat("w1:p1", in: app)
        let open = app.buttons["terminal.open"].firstMatch
        XCTAssertTrue(open.waitUntilExists(timeout: 10))
        open.tap()
        let screen = app.element("terminal.screen")
        XCTAssertTrue(screen.waitUntilExists(timeout: 10), "沒有終端機畫面")
        let shown = NSPredicate(format: "value CONTAINS %@", "demo@purrdr")
        XCTAssertTrue(screen.wait(for: shown, timeout: 10), "等待的條件沒有成立")
        capture("08-terminal", app)
    }

    @MainActor
    func test09MultipleHostsOneUnreachable() {
        // 正式 Demo 的示範主機(#34,與 review-notes.md 相同):Studio Mac 與連不上的 Build Box。
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"])
        XCTAssertTrue(app.element("agent.row.demo/w2:p1").waitUntilExists(timeout: 10))
        let unreachable = app.element("agentList.error.DE300000-0000-4000-8000-000000000002")
        XCTAssertTrue(app.reveal(unreachable, timeout: 20), "沒有連不上的主機")
        capture("09-multiple-hosts", app)
    }

    @MainActor
    func test10Account() {
        // 沒登入的帳號 sheet 直接是登入頁(#328),所以以已加入會員的假後台啟動才看得到步驟卡(#246)。
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember"])
        XCTAssertTrue(app.buttons["toolbar.account"].waitUntilExists(timeout: 10))
        app.buttons["toolbar.account"].tap()
        XCTAssertTrue(app.element("account.plusSetup").waitUntilExists(timeout: 10), "帳號頁沒有步驟卡")
        capture("10-account", app)
    }

    @MainActor
    func test11Welcome() {
        let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"])
        XCTAssertTrue(app.element("sheet.welcome").waitUntilExists(timeout: 10))
        capture("11-welcome", app)
    }

    @MainActor
    func test12AddHostGuide() {
        // 沒有主機的空狀態(#332)進新增主機引導的第一頁(#341)。
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingNoHosts"])
        let add = app.buttons["agentList.addHost"]
        XCTAssertTrue(add.waitUntilExists(timeout: 10), "沒有沒有主機的空狀態")
        add.tap()
        XCTAssertTrue(app.buttons["guide.option.ssh"].waitUntilExists(timeout: 5), "沒有開出新增主機引導")
        capture("12-add-host-guide", app)
    }

    @MainActor
    func test13DataUsage() {
        // 設定 → 數據用量(#354):以種子資料畫出摘要、長條圖與各台主機。
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnreachableHost", "-seedDataUsage"])
        app.openMoreMenuItem("menu.settings")
        let entry = app.buttons["settings.dataUsage"]
        XCTAssertTrue(entry.waitUntilExists(timeout: 5), "設定沒有數據用量")
        entry.tap()
        XCTAssertTrue(app.element("dataUsage.chart").waitUntilExists(timeout: 10), "沒有長條圖")
        capture("13-data-usage", app)
    }

    @MainActor
    func test14PlusPaywall() {
        // Purrdr Plus 頁(#323):已加入會員、未開通時是付費牆。
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember", "-seedHost"])
        app.openPlusPaywall()
        XCTAssertTrue(app.element("plus.disclosure").waitUntilExists(timeout: 15), "沒有付費牆")
        capture("14-plus", app)
    }

    // MARK: - 設計稿比對(#267、#276):重做的頁面各存淺色與深色，與原型並排確認

    /// 以淺色、深色各啟動一次，打開同一頁後存成「design-<名稱>-light／dark」。
    /// 外觀經啟動參數覆寫 `appearance`(只在這次啟動有效，不寫進 UserDefaults)。
    @MainActor
    private func captureDesign(_ name: String, open: @MainActor (XCUIApplication) -> Void) {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication.launchUITesting(flags: ["-appearance", appearance])
            open(app)
            capture("design-\(name)-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    func testDesign01AgentsView() {
        captureDesign("01-agents") { app in
            XCTAssertTrue(app.element("agent.row.demo/w2:p1").waitUntilExists(timeout: 10), "沒有 Agents 列")
        }
    }

    @MainActor
    func testDesign02SpacesView() {
        captureDesign("02-spaces") { app in
            app.switchListMode(to: "Spaces")
            XCTAssertTrue(app.element("spaces.section.demo/w3").waitUntilExists(timeout: 10), "沒有 workspace 段落")
        }
    }

    @MainActor
    func testDesign03Chat() {
        captureDesign("03-chat") { app in
            _ = self.openChat("w1:p1", in: app)
            // 訊息呈現(#351):Agent 回覆的頭像、表格與程式碼區塊都在畫面內。
            XCTAssertTrue(app.element("conversation.agent.header").waitUntilExists(timeout: 10), "沒有 Agent 回覆開頭")
            XCTAssertTrue(app.element("conversation.table").exists, "沒有表格")
        }
    }

    @MainActor
    func testDesign04NeedsYou() {
        captureDesign("04-needs-you") { app in
            _ = self.openChat("w2:p1", in: app)
            XCTAssertTrue(app.staticTexts["Do you want to proceed?"].waitUntilExists(timeout: 15), "沒有「需要你」的提問")
        }
    }

    @MainActor
    func testDesign05NewChat() {
        captureDesign("05-new-chat") { app in
            app.openMoreMenuItem("menu.newChat")
            XCTAssertTrue(app.textFields["newChat.folder"].waitUntilExists(timeout: 10), "沒有開出新增聊天")
        }
    }

    @MainActor
    func testDesign06Files() {
        captureDesign("06-files") { app in
            app.openMoreMenuItem("menu.files")
            XCTAssertTrue(app.buttons["files.row.ledger"].firstMatch.waitUntilExists(timeout: 10), "沒有列出家目錄")
        }
    }

    @MainActor
    func testDesign07Settings() {
        captureDesign("07-settings") { app in
            app.openMoreMenuItem("menu.settings")
            XCTAssertTrue(app.element("sheet.settings").waitUntilExists(timeout: 10), "沒有開出設定")
        }
    }
}
