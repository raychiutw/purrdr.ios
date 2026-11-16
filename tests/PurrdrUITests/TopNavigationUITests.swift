import XCTest

/// iPhone 頂層導覽(#37 故事 21):列表工具列「⋯」選單進入設定與主機、「+」新增對話，
/// 各自以 sheet 開啟，「完成」回到同一個列表;設定支援深層連結 `purrdr://settings`。
final class TopNavigationUITests: XCTestCase {
    private let settingsLink = URL(string: "purrdr://settings")!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testMoreMenuOpensSettingsAndDoneReturnsToList() {
        let app = XCUIApplication.launchUITesting()

        openMoreMenuItem("menu.settings", in: app)
        assertSheet("sheet.settings", isShownIn: app)

        app.buttons["sheet.done"].tap()
        assertBackOnAgentList(app)
    }

    @MainActor
    func testMoreMenuOpensHostsAndDoneReturnsToList() {
        let app = XCUIApplication.launchUITesting()

        openMoreMenuItem("menu.hosts", in: app)
        assertSheet("sheet.hosts", isShownIn: app)

        app.buttons["sheet.done"].tap()
        assertBackOnAgentList(app)
    }

    @MainActor
    func testPlusOpensNewChat() {
        let app = XCUIApplication.launchUITesting()

        let plus = app.buttons["toolbar.newChat"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "列表工具列沒有「+」")
        plus.tap()
        // 新增對話是表單：左上「Cancel」,不是「完成」(HIG 檢核清單 20.3)。
        XCTAssertTrue(app.descendants(matching: .any)["sheet.newChat"].firstMatch.waitForExistence(timeout: 10), "沒有開出新增對話")
        let cancel = app.buttons["newChat.cancel"]
        XCTAssertTrue(cancel.exists, "新增對話沒有「Cancel」")
        XCTAssertFalse(app.buttons["sheet.done"].exists, "新增對話不該同時有「完成」")

        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5), "sheet 沒有關閉")
        XCTAssertTrue(app.descendants(matching: .any)["agent.row.demo/w1:p1"].firstMatch.exists, "沒有回到 Agent 列表")
    }

    /// icon-only 按鈕都要有 accessibility label(HIG 檢核清單 20.2)。
    @MainActor
    func testIconOnlyToolbarButtonsHaveLabels() {
        let app = XCUIApplication.launchUITesting()

        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "列表工具列沒有「⋯」")
        XCTAssertEqual(more.label, "More")
        XCTAssertEqual(app.buttons["toolbar.newChat"].label, "New Chat")
    }

    @MainActor
    func testSettingsDeepLinkFromColdLaunch() {
        let app = XCUIApplication.uiTesting()
        app.terminate()

        app.open(settingsLink)

        assertSheet("sheet.settings", isShownIn: app)
    }

    @MainActor
    func testSettingsDeepLinkFromBackground() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.buttons["toolbar.more"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "app 沒有進背景")

        app.open(settingsLink)

        assertSheet("sheet.settings", isShownIn: app)
    }

    // MARK: - 輔助

    @MainActor
    private func openMoreMenuItem(_ identifier: String, in app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "列表工具列沒有「⋯」")
        more.tap()
        let item = app.buttons[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "「⋯」選單沒有 \(identifier)")
        item.tap()
    }

    @MainActor
    private func assertSheet(_ identifier: String, isShownIn app: XCUIApplication) {
        let sheet = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "沒有開出 \(identifier)")
        XCTAssertTrue(app.buttons["sheet.done"].exists, "\(identifier) 沒有「完成」")
    }

    @MainActor
    private func assertBackOnAgentList(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["sheet.done"].waitForNonExistence(timeout: 5), "sheet 沒有關閉")
        XCTAssertTrue(app.descendants(matching: .any)["agent.row.demo/w1:p1"].firstMatch.exists, "沒有回到 Agent 列表")
    }
}
