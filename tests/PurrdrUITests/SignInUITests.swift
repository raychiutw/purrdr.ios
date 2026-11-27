import XCTest

final class SignInUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// AX 最大字級只啟動一次(原本 SignIn 與 Plus 各自啟動 AX 字級):
    /// 「需要你」段落不爆版、4 個 tab 都在 tab bar 上 → 付費牆的揭露在 AX 字級仍完整、可點 → 關閉付費牆回到列表 →
    /// 帳號(經溢出選單)與登入仍點得到、HIG:Sign in with Apple 按鈕不小於 Google 按鈕且不需捲動就看得到。
    /// 預設字級的登入頁量測在 `PlusUITests` 的預設字級那次啟動(換字級的測試連結會把畫面重置回列表,所以不能在同一次啟動內換)。
    @MainActor
    func testAccessibilitySizeNeedsYouTabBarPaywallDisclosuresAndSignInButtons() {
        let accessibilityXXXL = "UICTContentSizeCategoryAccessibilityXXXL"
        let app = XCUIApplication.launchUITesting(contentSize: accessibilityXXXL)
        XCTAssertTrue(app.chatListReady.waitUntilExists(timeout: 15))

        // AX 最大字級不爆版:段落標題與列都還在畫面上。
        let header = app.element("needsYou.section")
        XCTAssertTrue(header.waitUntilExists(timeout: 15), "AX 字級沒有「需要你」段落")
        XCTAssertTrue(app.element("needsYou.tab.demo/w2:t1").waitUntilExists(timeout: 5), "AX 字級段落裡沒有列")
        XCTAssertLessThanOrEqual(header.frame.maxX, app.frame.maxX + 1, "標題超出畫面寬度")

        // AX 字級下 4 個 tab 都在 tab bar 上,帳號與新增聊天仍可從工具列(或溢出選單)點到。
        for tab in [AppTab.chats, .files, .hosts, .traffic] {
            XCTAssertTrue(
                app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", tab.rawValue)).firstMatch.waitUntilExists(timeout: 5),
                "tab bar 沒有 \(tab.rawValue)")
        }

        // 付費牆(深層連結開的 sheet):AX 字級下揭露完整;預設年繳。關掉就回到列表。
        app.openPlusPaywall()
        XCTAssertTrue(
            app.descendants(matching: .any)["plus.benefits"].firstMatch.waitUntilExists(timeout: 15), "沒有每期內容(AX 最大字級)")
        PlusUITests.assertPaywallDisclosures(in: app, size: "AX 最大字級", selectedPrice: "$39.99")
        let close = app.buttons["plus.close"]
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "AX 字級下付費牆沒有關閉鈕")
        close.tap()
        XCTAssertTrue(app.chatListReady.waitUntilExists(timeout: 10), "關閉付費牆後沒有回到列表")

        // 未登入時帳號鈕開的是「登入或加入」選擇頁(#408),不是帳號頁。
        app.openAccount()
        XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 10), "大字級下沒有開出登入或加入選擇頁")
        let signInEntry = app.buttons["account.entry.signIn"]
        app.scrollIntoView(signInEntry, search: .down)
        XCTAssertTrue(signInEntry.waitUntilExists(timeout: 5), "大字級下找不到「登入」")
        signInEntry.tap()

        Self.assertSignInButtons(in: app, label: "AX 字級")
    }

    /// HIG:Sign in with Apple 按鈕不小於 Google 按鈕，且不需捲動就看得到。
    @MainActor
    static func assertSignInButtons(in app: XCUIApplication, label: String) {
        let apple = app.buttons["member.signIn.apple"]
        let google = app.buttons["member.signIn.google"]
        XCTAssertTrue(apple.waitUntilExists(timeout: 10), "沒有 Sign in with Apple 按鈕(\(label))")
        XCTAssertTrue(google.exists)
        XCTAssertGreaterThanOrEqual(apple.frame.width, google.frame.width, label)
        XCTAssertGreaterThanOrEqual(apple.frame.height, google.frame.height, label)
        XCTAssertGreaterThanOrEqual(apple.frame.width, 140)
        XCTAssertGreaterThanOrEqual(apple.frame.height, 44)
        // 不需捲動：兩個按鈕都完整落在視窗內且可以點。
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(apple.frame), "Apple 按鈕超出畫面:\(apple.frame)")
        XCTAssertTrue(window.contains(google.frame), "Google 按鈕超出畫面:\(google.frame)")
        XCTAssertTrue(apple.isHittable)
        XCTAssertTrue(google.isHittable)
    }
}
