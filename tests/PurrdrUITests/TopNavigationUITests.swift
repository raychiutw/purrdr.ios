import XCTest

/// iPhone 頂層導覽(#376、#390):底部 5 個 tab(聊天、檔案、主機、流量、設定),新增聊天在聊天 tab 右上以 sheet 開啟;
/// 設定支援深層連結 `purrdr://settings`(選設定 tab)。
final class TopNavigationUITests: XCTestCase {
    private let settingsLink = URL(string: "purrdr://settings")!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsTabShowsSettingsAndChatsTabReturnsToList() {
        let app = XCUIApplication.launchUITesting()

        app.openSettingsTab()
        XCTAssertFalse(app.buttons["sheet.close"].exists, "設定是 tab,不該有關閉鈕")

        app.openTab(.chats)
        XCTAssertTrue(app.reveal(app.descendants(matching: .any)["agent.row.demo/w1:p1"].firstMatch), "沒有回到 Agent 列表")
    }

    @MainActor
    func testHostsTabShowsHostOverview() {
        let app = XCUIApplication.launchUITesting()

        app.openHostsTab()
        XCTAssertTrue(app.descendants(matching: .any)["sheet.hosts"].firstMatch.exists, "沒有主機總頁")
        XCTAssertFalse(app.buttons["sheet.close"].exists, "主機是 tab,不該有關閉鈕")
    }

    @MainActor
    func testNewChatButtonOpensNewChat() {
        let app = XCUIApplication.launchUITesting()

        app.openNewChatSheet()
        // 新增對話是表單：左上「Cancel」,不是「完成」(HIG 檢核清單 20.3)。
        XCTAssertTrue(app.descendants(matching: .any)["sheet.newChat"].firstMatch.waitUntilExists(timeout: 10), "沒有開出新增對話")
        let cancel = app.buttons["newChat.cancel"]
        XCTAssertTrue(cancel.exists, "新增對話沒有「Cancel」")
        XCTAssertFalse(app.buttons["sheet.close"].exists, "新增對話不該同時有關閉鈕")

        cancel.tap()
        XCTAssertTrue(cancel.waitUntilGone(timeout: 5), "sheet 沒有關閉")
        XCTAssertTrue(app.reveal(app.descendants(matching: .any)["agent.row.demo/w1:p1"].firstMatch), "沒有回到 Agent 列表")
    }

    /// icon-only 按鈕都要有 accessibility label(HIG 檢核清單 20.2);每顆 ≥ 44pt。
    @MainActor
    func testIconOnlyToolbarButtonsHaveLabelsAndHitTargets() {
        let app = XCUIApplication.launchUITesting()

        let newChat = app.buttons["toolbar.newChat"].firstMatch
        XCTAssertTrue(newChat.waitUntilExists(timeout: 10), "聊天 tab 沒有新增聊天")
        XCTAssertEqual(newChat.label, "New Chat")
        XCTAssertEqual(app.buttons["toolbar.account"].firstMatch.label, "Account")
        XCTAssertHitTarget(app.buttons["toolbar.account"].firstMatch)
        XCTAssertLessThan(newChat.frame.maxX, app.buttons["toolbar.account"].firstMatch.frame.minX, "兩顆右上按鈕重疊")
    }

    @MainActor
    func testTabBarListsFiveTabsAndNoMoreMenu() {
        let app = XCUIApplication.launchUITesting()

        for tab in [AppTab.chats, .files, .hosts, .traffic, .settings] {
            XCTAssertTrue(
                app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", tab.rawValue)).firstMatch.waitUntilExists(timeout: 10),
                "tab bar 沒有 \(tab.rawValue)")
        }
        XCTAssertFalse(app.buttons["toolbar.more"].exists, "不該再有「⋯」選單")
    }

    @MainActor
    func testSettingsDeepLinkFromColdLaunch() {
        let app = XCUIApplication.uiTesting()
        app.terminate()

        app.open(settingsLink)

        XCTAssertTrue(app.element("sheet.settings").waitUntilExists(timeout: 10), "沒有開出設定")
    }

    @MainActor
    func testSettingsDeepLinkFromBackground() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.buttons["toolbar.newChat"].waitUntilExists(timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "app 沒有進背景")

        app.open(settingsLink)

        XCTAssertTrue(app.element("sheet.settings").waitUntilExists(timeout: 10), "沒有開出設定")
    }
}
