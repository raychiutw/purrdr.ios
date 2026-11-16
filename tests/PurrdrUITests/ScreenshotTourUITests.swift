import XCTest

/// 截圖巡覽(#34):以 Demo 主機逐一打開主要畫面並存截圖(XCTAttachment,永久保留)。
///
/// `scripts/screenshots.sh` 只跑這個類別，再從 result bundle 匯出截圖;完整 UI 套件也會跑它，
/// 所以它同時是「Demo 演得出每個主要功能」的煙霧測試。每張圖一個測試，彼此獨立，其中一張壞了不影響其他張。
/// 截圖名稱的數字是 App Store 截圖的建議順序。
final class ScreenshotTourUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
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
        let row = element("agent.row.demo/\(paneID)", in: app)
        XCTAssertTrue(app.reveal(row), "列表上沒有 \(paneID)")
        row.tap()
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10), "沒有輸入框")
        return text
    }

    @MainActor
    func test01AgentListWithWorkspaceCards() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(element("agent.row.demo/w2:p1", in: app).waitForExistence(timeout: 10))
        // Spaces 檢視：notes 有 Codex 與 shell,是 workspace 卡片。
        XCTAssertTrue(app.staticTexts["notes"].waitForExistence(timeout: 10), "沒有 workspace 卡片")
        capture("01-agent-list", app)
    }

    @MainActor
    func test02NeedsYouAnswer() {
        let app = XCUIApplication.launchUITesting()
        _ = openChat("w2:p1", in: app)
        XCTAssertTrue(app.staticTexts["Do you want to proceed?"].waitForExistence(timeout: 15), "沒有「需要你」的提問")
        capture("02-needs-you", app)
    }

    @MainActor
    func test03ConversationWithSubagent() {
        let app = XCUIApplication.launchUITesting()
        _ = openChat("w2:p1", in: app)
        let card = app.staticTexts["Check how the widget refreshes"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "沒有 subagent 卡")
        // 讓 subagent 卡在畫面中間。
        for _ in 0..<4 where !card.isHittable { app.swipeDown() }
        capture("03-subagent", app)
    }

    @MainActor
    func test04SlashMenu() {
        let app = XCUIApplication.launchUITesting()
        let text = openChat("w1:p1", in: app)
        text.tap()
        text.typeText("/")
        XCTAssertTrue(element("slash.row.demo-kit:changelog", in: app).waitForExistence(timeout: 10), "沒有 slash 選單")
        capture("04-slash-menu", app)
    }

    @MainActor
    func test05ModelPanelCard() {
        let app = XCUIApplication.launchUITesting()
        let text = openChat("w1:p1", in: app)
        text.tap()
        text.typeText("/model")
        element("slash.row.model", in: app).tap()
        XCTAssertTrue(element("panel.card", in: app).waitForExistence(timeout: 10), "沒有 /model 面板卡片")
        element("composer.hideKeyboard", in: app).tap()
        capture("05-model-panel", app)
    }

    @MainActor
    func test06EffortPanelCard() {
        let app = XCUIApplication.launchUITesting()
        let text = openChat("w1:p1", in: app)
        text.tap()
        text.typeText("/effort")
        element("slash.row.effort", in: app).tap()
        XCTAssertTrue(element("panel.levels", in: app).waitForExistence(timeout: 10), "沒有 /effort 面板卡片")
        element("composer.hideKeyboard", in: app).tap()
        capture("06-effort-panel", app)
    }

    @MainActor
    func test07ShellCommand() {
        let app = XCUIApplication.launchUITesting()
        let text = openChat("w1:p1", in: app)
        text.tap()
        text.typeText("!git status")
        element("composer.send", in: app).tap()
        XCTAssertTrue(element("conversation.shell", in: app).waitForExistence(timeout: 15), "沒有 shell 區塊")
        element("composer.hideKeyboard", in: app).tap()
        capture("07-shell-command", app)
    }

    @MainActor
    func test08Terminal() {
        let app = XCUIApplication.launchUITesting()
        _ = openChat("w1:p1", in: app)
        let open = app.buttons["terminal.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let screen = element("terminal.screen", in: app)
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "沒有終端機畫面")
        let shown = NSPredicate(format: "value CONTAINS %@", "demo@purrdr")
        expectation(for: shown, evaluatedWith: screen)
        waitForExpectations(timeout: 10)
        capture("08-terminal", app)
    }

    @MainActor
    func test09MultipleHostsOneUnreachable() {
        // 正式 Demo 的示範主機(#34,與 review-notes.md 相同):Studio Mac 與連不上的 Lab Server。
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"])
        XCTAssertTrue(element("agent.row.demo/w2:p1", in: app).waitForExistence(timeout: 10))
        let unreachable = element("agentList.error.DE300000-0000-4000-8000-000000000002", in: app)
        XCTAssertTrue(app.reveal(unreachable, timeout: 20), "沒有連不上的主機")
        capture("09-multiple-hosts", app)
    }

    @MainActor
    func test10PushSettings() {
        let app = XCUIApplication.uiTesting()
        app.launch()
        app.open(URL(string: "purrdr://settings")!)
        XCTAssertTrue(element("sheet.settings", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["settings.push"].waitForExistence(timeout: 10), "設定頁沒有推播開關")
        capture("10-push-settings", app)
    }

    @MainActor
    func test11Welcome() {
        let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"])
        XCTAssertTrue(element("sheet.welcome", in: app).waitForExistence(timeout: 10))
        capture("11-welcome", app)
    }
}
