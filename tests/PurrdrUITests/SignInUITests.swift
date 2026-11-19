import XCTest

final class SignInUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 聊天不需要登入：啟動直接看到 Agent 列表，沒有登入畫面擋著。
    @MainActor
    func testAgentListNeedsNoSignIn() {
        let app = XCUIApplication.launchUITesting()

        XCTAssertTrue(app.descendants(matching: .any)["agent.row.demo/w2:p1"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["member.signIn.apple"].exists)
    }

    /// HIG:Sign in with Apple 按鈕不小於 Google 按鈕，且不需捲動就看得到。
    @MainActor
    func testAppleButtonIsNotSmallerThanGoogleAndVisibleWithoutScrolling() {
        for contentSize in [nil, "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication.launchUITesting(contentSize: contentSize)
            openSignIn(in: app)

            let apple = app.buttons["member.signIn.apple"]
            let google = app.buttons["member.signIn.google"]
            XCTAssertTrue(apple.waitForExistence(timeout: 10), "沒有 Sign in with Apple 按鈕(\(contentSize ?? "預設字級"))")
            XCTAssertTrue(google.exists)
            XCTAssertGreaterThanOrEqual(apple.frame.width, google.frame.width, contentSize ?? "預設字級")
            XCTAssertGreaterThanOrEqual(apple.frame.height, google.frame.height, contentSize ?? "預設字級")
            XCTAssertGreaterThanOrEqual(apple.frame.width, 140)
            XCTAssertGreaterThanOrEqual(apple.frame.height, 44)
            // 不需捲動：兩個按鈕都完整落在視窗內且可以點。
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(window.contains(apple.frame), "Apple 按鈕超出畫面:\(apple.frame)")
            XCTAssertTrue(window.contains(google.frame), "Google 按鈕超出畫面:\(google.frame)")
            XCTAssertTrue(apple.isHittable)
            XCTAssertTrue(google.isHittable)
            app.terminate()
        }
    }

    /// 頁首只有標題(#236):登入頁不放功能說明文字。
    @MainActor
    func testSignInShowsOnlyTitle() {
        let app = XCUIApplication.launchUITesting()
        openSignIn(in: app)

        XCTAssertTrue(app.buttons["member.signIn.apple"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sign in to use Purrdr Plus"].exists, "沒有標題")
        let description = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "A member account is only needed", "never need an account"))
        XCTAssertEqual(description.count, 0, "登入頁仍有說明文字")
    }

    @MainActor
    private func openSignIn(in app: XCUIApplication) {
        app.openMemberFromSettings()
    }
}
