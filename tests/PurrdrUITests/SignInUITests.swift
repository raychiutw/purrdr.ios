import XCTest

final class SignInUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 以 AX 最大字級啟動,再以預設字級重新啟動(原本 4 個測試、5 次啟動,現在 2 次):
    /// AX 字級——「需要你」段落不爆版、4 個 tab 都在 tab bar 上、帳號(經溢出選單)與登入仍點得到、
    /// HIG:Sign in with Apple 按鈕不小於 Google 按鈕且不需捲動就看得到;
    /// 預設字級——登入頁同樣的量測,加上(#328,原型 A)標題與簡短說明、不放舊版的功能說明文字。
    @MainActor
    func testAccessibilitySizeThenDefaultSizeSignInButtonsTabBarAndNeedsYouSection() {
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
        // 未登入時帳號鈕開的是「登入或加入」選擇頁(#408),不是帳號頁。
        app.openAccount()
        XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 10), "大字級下沒有開出登入或加入選擇頁")
        let signInEntry = app.buttons["account.entry.signIn"]
        app.scrollIntoView(signInEntry, search: .down)
        XCTAssertTrue(signInEntry.waitUntilExists(timeout: 5), "大字級下找不到「登入」")
        signInEntry.tap()

        assertSignInButtons(in: app, label: "AX 字級")
        app.terminate()

        // 預設字級(重新啟動;換字級的測試連結 `purrdr://testing-content-size` 會把畫面重置回列表,所以不能在同一次啟動內換):
        // 登入頁同樣的量測,加上(#328,原型 A)標題與簡短說明、不放舊版的功能說明文字。
        let defaultApp = XCUIApplication.launchUITesting()
        defaultApp.openSignInFromAccount()
        assertSignInButtons(in: defaultApp, label: "預設字級")
        XCTAssertTrue(defaultApp.staticTexts["Sign In to Purrdr"].exists, "沒有標題")
        let description = defaultApp.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "A member account is only needed", "never need an account"))
        XCTAssertEqual(description.count, 0, "登入頁仍有說明文字")
    }

    /// HIG:Sign in with Apple 按鈕不小於 Google 按鈕，且不需捲動就看得到。
    @MainActor
    private func assertSignInButtons(in app: XCUIApplication, label: String) {
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
