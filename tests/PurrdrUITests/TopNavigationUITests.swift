import XCTest

/// iPhone 頂層導覽(#376、#390):底部 5 個 tab(聊天、檔案、主機、流量、設定),新增聊天在聊天 tab 右上以 sheet 開啟;
/// 設定支援深層連結 `purrdr://settings`(開帳號與設定 sheet,#503)。
final class TopNavigationUITests: XCTestCase {
    private let settingsLink = URL(string: "purrdr://settings")!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAccountSheetHoldsSettingsAndClosesWithXBackToSameTab() {
        let app = XCUIApplication.launchUITesting()
        app.openTab(.files)

        app.openSettingsSheet()
        XCTAssertTrue(app.element("settings.version").exists || app.scrollIntoView(app.element("settings.version"), search: .down), "帳號與設定第一層沒有設定內容")
        XCTAssertFalse(app.buttons["sheet.done"].exists, "帳號與設定不該有完成鈕")

        app.closeAccountSheet()
        XCTAssertTrue(app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Files")).firstMatch.isSelected, "關閉後沒有回到原本的 tab")
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
        XCTAssertTrue(app.reveal(app.descendants(matching: .any)["spaces.tab.demo/w1:t1"].firstMatch), "沒有回到 Agent 列表")
    }

    /// icon-only 按鈕都要有 accessibility label(HIG 檢核清單 20.2);每顆 ≥ 44pt。
    @MainActor
    func testIconOnlyToolbarButtonsHaveLabelsAndHitTargets() {
        let app = XCUIApplication.launchUITesting()

        let newChat = app.buttons["toolbar.newChat"].firstMatch
        XCTAssertTrue(newChat.waitUntilExists(timeout: 10), "聊天 tab 沒有新增聊天")
        XCTAssertEqual(newChat.label, "New Chat")
        XCTAssertEqual(app.buttons["toolbar.account"].firstMatch.label, "Account")
        XCTAssertLessThan(newChat.frame.maxX, app.buttons["toolbar.account"].firstMatch.frame.minX, "兩顆右上按鈕重疊")
        // 點擊範圍(HIG 44pt):帳號鈕是工具列的 44pt 玻璃圓鈕,XCUI 回報的 frame 只有裡面 30pt 的頭像,
        // 所以改驗行為——點在頭像外 18pt(圓鈕範圍內)也要開得出帳號頁。
        app.buttons["toolbar.account"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 18, dy: 0)).tap()
        XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 10), "點頭像外圍(44pt 範圍內)沒有開出帳號頁")
    }

    /// 各 tab 頂端的版面規則(#475、#500):大標題的水平與垂直位置、帳號鈕的高度與位置在每個 tab 一致;
    /// 右側控制項(膠囊或單顆圓鈕)的右緣都貼著帳號鈕左邊。只比各 tab 之間的相對關係(容差內相等),不寫死像素。
    @MainActor
    func testTopBarsAlignAcrossTabs() {
        let app = XCUIApplication.launchUITesting()
        let tabs: [(name: String, open: () -> Void, title: String, control: String)] = [
            ("聊天", { app.openTab(.chats) }, "Chats", "toolbar.newChat"),
            ("檔案", { app.openTab(.files) }, "Files", "files.upload"),
            ("主機", { app.openHostsTab() }, "Hosts", "hosts.add"),
            ("流量", { app.openTab(.traffic) }, "Traffic", "dataUsage.host"),
        ]
        var titleFrames: [(name: String, frame: CGRect)] = []
        var accountFrames: [(name: String, frame: CGRect)] = []
        for tab in tabs {
            tab.open()
            let title = app.staticTexts["topBar.title"].firstMatch
            XCTAssertTrue(title.waitUntilExists(timeout: 10), "\(tab.name) tab 沒有大標題")
            XCTAssertEqual(title.label, tab.title, "\(tab.name) tab 的大標題不是 tab 名稱")
            let account = app.buttons["toolbar.account"].firstMatch
            XCTAssertTrue(account.waitUntilExists(timeout: 5), "\(tab.name) tab 沒有帳號鈕")
            let control = app.descendants(matching: .any)[tab.control].firstMatch
            XCTAssertTrue(control.waitUntilExists(timeout: 5), "\(tab.name) tab 沒有右側控制項(\(tab.control))")
            XCTAssertLessThan(control.frame.maxX, account.frame.minX, "\(tab.name) tab 的右側控制項和帳號鈕重疊")
            titleFrames.append((tab.name, title.frame))
            accountFrames.append((tab.name, account.frame))
            print("TOPBAR \(tab.name) title=\(title.frame) account=\(account.frame) control=\(control.frame)")
        }
        let titleReference = titleFrames[0]
        for entry in titleFrames.dropFirst() {
            XCTAssertEqual(entry.frame.minX, titleReference.frame.minX, accuracy: 2, "\(entry.name) tab 的大標題水平位置和\(titleReference.name)不同")
            XCTAssertEqual(entry.frame.midY, titleReference.frame.midY, accuracy: 2, "\(entry.name) tab 的大標題垂直位置和\(titleReference.name)不同")
        }
        let accountReference = accountFrames[0]
        for entry in accountFrames.dropFirst() {
            XCTAssertEqual(entry.frame.minX, accountReference.frame.minX, accuracy: 2, "\(entry.name) tab 的帳號鈕水平位置和\(accountReference.name)不同")
            XCTAssertEqual(entry.frame.height, accountReference.frame.height, accuracy: 2, "\(entry.name) tab 的帳號鈕高度和\(accountReference.name)不同")
            XCTAssertEqual(entry.frame.midY, accountReference.frame.midY, accuracy: 2, "\(entry.name) tab 的帳號鈕垂直位置和\(accountReference.name)不同")
        }
    }

    @MainActor
    func testTabBarListsFourTabsAndNoSettingsTab() {
        let app = XCUIApplication.launchUITesting()

        for tab in [AppTab.chats, .files, .hosts, .traffic] {
            XCTAssertTrue(
                app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", tab.rawValue)).firstMatch.waitUntilExists(timeout: 10),
                "tab bar 沒有 \(tab.rawValue)")
        }
        XCTAssertFalse(app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Settings")).firstMatch.exists, "不該再有設定 tab")
        XCTAssertFalse(app.buttons["toolbar.more"].exists, "不該再有「⋯」選單")
    }

    @MainActor
    func testSettingsDeepLinkFromColdLaunch() {
        let app = XCUIApplication.uiTesting()
        app.terminate()

        app.open(settingsLink)

        app.waitForAccountSheet()
    }

    @MainActor
    func testSettingsDeepLinkFromBackground() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.buttons["toolbar.newChat"].waitUntilExists(timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "app 沒有進背景")

        app.open(settingsLink)

        app.waitForAccountSheet()
    }
}
