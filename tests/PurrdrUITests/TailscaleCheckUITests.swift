import XCTest

/// Tailscale SSH check mode:Demo 主機的 check mode 情境(第一個指令先要求重新驗證)。
final class TailscaleCheckUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 要求驗證時顯示提示：開啟驗證頁的按鈕與取消;取消後提示收起，列表說明已取消。
    @MainActor
    func testPromptCanBeCancelled() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoTailscaleCheck"])

        let prompt = element("tailscaleCheck.prompt", in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "沒有出現 Tailscale 驗證提示")
        XCTAssertTrue(app.staticTexts["Sign In to Tailscale"].exists)
        XCTAssertTrue(element("tailscaleCheck.open", in: app).isHittable, "開啟驗證頁的按鈕按不到")

        element("tailscaleCheck.cancel", in: app).tap()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: prompt)
        waitForExpectations(timeout: 5)
        let cancelled = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Tailscale sign-in was canceled'")).firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout: 5), "列表沒有說明驗證已取消")
    }

    /// 驗證完成後不用任何操作：提示收起、Agent 列表自動載入。
    @MainActor
    func testContinuesAfterSignIn() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoTailscaleCheckCompletes"])

        let prompt = element("tailscaleCheck.prompt", in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "沒有出現 Tailscale 驗證提示")
        app.triggerDemoScenario()

        XCTAssertTrue(element("agent.row.demo/w2:p1", in: app).waitForExistence(timeout: 15), "驗證完成後沒有自動載入 Agent")
        XCTAssertFalse(prompt.exists, "驗證完成後提示沒有收起")
    }

    /// 最大字級(AX5)下按鈕改成上下排列，兩個按鈕都按得到。
    @MainActor
    func testPromptAtLargestTextSize() {
        let app = XCUIApplication.launchUITesting(
            flags: ["-demoTailscaleCheck"], contentSize: "UICTContentSizeCategoryAccessibilityXXXL")

        XCTAssertTrue(element("tailscaleCheck.prompt", in: app).waitForExistence(timeout: 10))
        let open = element("tailscaleCheck.open", in: app)
        let cancel = element("tailscaleCheck.cancel", in: app)
        XCTAssertTrue(open.isHittable, "AX5 下開啟驗證頁的按鈕按不到")
        XCTAssertTrue(cancel.isHittable, "AX5 下取消按鈕按不到")
        XCTAssertGreaterThanOrEqual(open.frame.height, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
    }
}
