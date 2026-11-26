import XCTest

/// Tailscale SSH check mode:Demo 主機的 check mode 情境(第一個指令先要求重新驗證)。
final class TailscaleCheckUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 要求驗證時顯示提示：開啟驗證頁的按鈕與取消;最大字級(AX5)下按鈕改成上下排列，兩個按鈕都按得到
    /// (同一次啟動內換字級);回到預設字級後取消,提示收起，列表說明已取消。
    @MainActor
    func testPromptAtLargestTextSizeThenCanBeCancelled() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoTailscaleCheck"])

        let prompt = app.element("tailscaleCheck.prompt")
        XCTAssertTrue(prompt.waitUntilExists(timeout: 10), "沒有出現 Tailscale 驗證提示")
        XCTAssertTrue(app.staticTexts["Sign In to Tailscale"].exists)
        XCTAssertTrue(app.element("tailscaleCheck.open").isHittable, "開啟驗證頁的按鈕按不到")

        // 最大字級:先確認字級真的變大(提示標題變高),否則下面的 AX5 斷言會變成量預設字級。
        let title = app.staticTexts["Sign In to Tailscale"]
        let defaultTitleHeight = title.frame.height
        app.setContentSize("UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(UITestWait.until(timeout: 5) { title.frame.height > defaultTitleHeight * 1.5 },
                      "字級沒有真的變大(換字級的測試連結沒有生效):標題高度 \(title.frame.height),預設 \(defaultTitleHeight)")
        let open = app.element("tailscaleCheck.open")
        let cancel = app.element("tailscaleCheck.cancel")
        XCTAssertTrue(open.isHittable, "AX5 下開啟驗證頁的按鈕按不到")
        XCTAssertTrue(cancel.isHittable, "AX5 下取消按鈕按不到")
        XCTAssertGreaterThanOrEqual(open.frame.height, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)

        app.setContentSize(nil)
        cancel.tap()

        let gone = NSPredicate(format: "exists == false")
        XCTAssertTrue(prompt.wait(for: gone, timeout: 5), "等待的條件沒有成立")
        let cancelled = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Tailscale sign-in was canceled'")).firstMatch
        XCTAssertTrue(cancelled.waitUntilExists(timeout: 5), "列表沒有說明驗證已取消")
    }
}
