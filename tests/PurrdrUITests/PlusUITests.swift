import XCTest

/// 付費牆(HIG 檢核清單 20.12)。商品來自 scheme 指定的 StoreKit 設定檔 `src/App/Purrdr.storekit`(不連 App Store)。
final class PlusUITests: XCTestCase {
    static let monthly = "plus.plan.com.raychiu.purrdr.plus.monthly"
    static let yearly = "plus.plan.com.raychiu.purrdr.plus.yearly"

    override func setUp() {
        continueAfterFailure = false
    }

    /// 每個方案揭露名稱、期間、每期內容、當地幣別的完整價格、試用後自動扣款;另有恢復購買、兌換代碼、條款與隱私權政策。
    @MainActor
    func testPaywallDisclosesEverythingRequired() {
        for contentSize in [nil, "UICTContentSizeCategoryAccessibilityXXXL"] {
            let size = contentSize ?? "預設字級"
            let app = XCUIApplication.launchUITesting(contentSize: contentSize)
            openPlus(in: app)

            let monthly = app.descendants(matching: .any)[Self.monthly].firstMatch
            XCTAssertTrue(monthly.waitForExistence(timeout: 15), "沒有月繳方案(\(size))")
            XCTAssertTrue(monthly.label.contains("Purrdr Plus Monthly"), monthly.label)
            XCTAssertTrue(monthly.label.contains("$4.99"), monthly.label)
            XCTAssertTrue(monthly.label.contains("month"), monthly.label)
            XCTAssertTrue(monthly.label.contains("2 weeks free"), monthly.label)
            let yearly = app.descendants(matching: .any)[Self.yearly].firstMatch
            XCTAssertTrue(yearly.label.contains("Purrdr Plus Yearly"), yearly.label)
            XCTAssertTrue(yearly.label.contains("$39.99"), yearly.label)
            XCTAssertTrue(yearly.label.contains("year"), yearly.label)

            let benefits = app.staticTexts["plus.benefits"]
            XCTAssertTrue(benefits.exists)
            XCTAssertTrue(benefits.label.contains("agent needs you"), benefits.label)

            let disclosure = app.staticTexts["plus.disclosure"]
            scrollTo(disclosure, in: app)
            XCTAssertTrue(disclosure.label.contains("2 weeks"), disclosure.label)
            XCTAssertTrue(disclosure.label.contains("$4.99"), disclosure.label)
            XCTAssertTrue(disclosure.label.contains("renews automatically"), disclosure.label)
            XCTAssertTrue(disclosure.label.contains("24 hours"), disclosure.label)

            for identifier in ["plus.restore", "plus.redeem", "plus.terms", "plus.privacy"] {
                let element = app.descendants(matching: .any)[identifier].firstMatch
                scrollTo(element, in: app)
                XCTAssertTrue(element.isHittable, "\(identifier) 點不到(\(size))")
                XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(identifier) 觸控目標太小(\(size))")
            }
            app.terminate()
        }
    }

    /// 選年繳時，說明跟著換成年繳的價格與期間。
    @MainActor
    func testDisclosureFollowsSelectedPlan() {
        let app = XCUIApplication.launchUITesting()
        openPlus(in: app)
        let yearly = app.descendants(matching: .any)[Self.yearly].firstMatch
        XCTAssertTrue(yearly.waitForExistence(timeout: 15))

        yearly.tap()

        XCTAssertTrue(yearly.isSelected || yearly.value as? String == "Selected", "\(String(describing: yearly.value))")
        let disclosure = app.staticTexts["plus.disclosure"]
        scrollTo(disclosure, in: app)
        XCTAssertTrue(disclosure.label.contains("$39.99"), disclosure.label)
        XCTAssertTrue(disclosure.label.contains("year"), disclosure.label)
    }

    /// 訂閱要先成為會員(權限記在會員身上):沒登入時主要按鈕帶去登入。付費牆可以關閉、不擋免費功能。
    @MainActor
    func testSubscribingNeedsSignInAndPaywallCanBeClosed() {
        let app = XCUIApplication.launchUITesting()
        openPlus(in: app)
        let subscribe = app.buttons["plus.subscribe"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 15))
        XCTAssertEqual(subscribe.label, "Sign In to Subscribe")

        subscribe.tap()
        XCTAssertTrue(app.buttons["member.signIn.apple"].waitForExistence(timeout: 10))
        app.buttons["member.done"].tap()

        let done = app.buttons["plus.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent.row.demo/w2:p1"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func openPlus(in app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let plus = app.buttons["menu.plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "找不到 \(element)")
        for _ in 0..<12 where !element.isHittable {
            app.swipeUp()
        }
    }
}
