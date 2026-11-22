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

            // 每期內容在最上面(App Store 3.1.2);大字級時方案在畫面外,下面再捲過去。
            let benefits = app.descendants(matching: .any)["plus.benefits"].firstMatch
            XCTAssertTrue(benefits.waitUntilExists(timeout: 15), "沒有每期內容(\(size))")
            XCTAssertTrue(benefits.label.contains("agent needs you"), benefits.label)

            let monthly = app.descendants(matching: .any)[Self.monthly].firstMatch
            app.scrollIntoView(monthly, search: .down)
            XCTAssertTrue(monthly.exists, "沒有月繳方案(\(size))")
            XCTAssertTrue(monthly.label.contains("Purrdr Plus Monthly"), monthly.label)
            XCTAssertTrue(monthly.label.contains("$4.99"), monthly.label)
            XCTAssertTrue(monthly.label.contains("month"), monthly.label)
            XCTAssertTrue(monthly.label.contains("2 weeks free"), monthly.label)
            let yearly = app.descendants(matching: .any)[Self.yearly].firstMatch
            app.scrollIntoView(yearly, search: .down)
            XCTAssertTrue(yearly.label.contains("Purrdr Plus Yearly"), yearly.label)
            XCTAssertTrue(yearly.label.contains("$39.99"), yearly.label)
            XCTAssertTrue(yearly.label.contains("year"), yearly.label)

            let disclosure = app.staticTexts["plus.disclosure"]
            app.scrollIntoView(disclosure, search: .down)
            XCTAssertTrue(disclosure.label.contains("2 weeks"), disclosure.label)
            XCTAssertTrue(disclosure.label.contains("$4.99"), disclosure.label)
            XCTAssertTrue(disclosure.label.contains("renews automatically"), disclosure.label)
            XCTAssertTrue(disclosure.label.contains("24 hours"), disclosure.label)

            for identifier in ["plus.restore", "plus.redeem", "plus.terms", "plus.privacy"] {
                let element = app.descendants(matching: .any)[identifier].firstMatch
                app.scrollIntoView(element, search: .down)
                XCTAssertTrue(element.isHittable, "\(identifier) 點不到(\(size))")
                XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(identifier) 觸控目標太小(\(size))")
            }
            app.terminate()
        }
    }

    /// 訂閱要先成為會員(權限記在會員身上):沒登入時主要按鈕帶去登入。付費牆可以關閉、不擋免費功能。
    @MainActor
    func testSubscribingNeedsSignInAndPaywallCanBeClosed() {
        let app = XCUIApplication.launchUITesting()
        openPlus(in: app)
        let subscribe = app.buttons["plus.subscribe"]
        XCTAssertTrue(subscribe.waitUntilExists(timeout: 15))
        XCTAssertEqual(subscribe.label, "Sign In to Subscribe")

        subscribe.tap()
        // 先選登入或加入(#408),選擇頁左上是關閉。
        XCTAssertTrue(app.buttons["account.entry.signIn"].waitUntilExists(timeout: 10))
        XCTAssertTrue(app.buttons["account.entry.join"].exists)
        app.buttons["member.signIn.cancel"].tap()

        // 深層連結開的是付費牆 sheet(#246),xmark 關掉就回到列表。
        let done = app.buttons["plus.close"]
        XCTAssertTrue(done.waitUntilExists(timeout: 5))
        done.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent.row.demo/w2:p1"].firstMatch.waitUntilExists(timeout: 5))
    }

    /// 頁首只有標題(#236);選年繳時說明跟著換成年繳的價格與期間;方案卡片有按壓回饋後(#234)按住一下再放開仍選取該方案。
    /// 一次啟動做完(#372:原本三個測試各啟動一次)。方案內容仍要寫出來(App Store 3.1.2)。
    @MainActor
    func testPaywallHeaderAndPlanSelection() {
        let app = XCUIApplication.launchUITesting()
        openPlus(in: app)

        XCTAssertTrue(app.staticTexts["plus.benefits"].waitUntilExists(timeout: 10), "沒有方案內容")
        XCTAssertFalse(app.scrollViews.staticTexts["Purrdr Plus"].exists, "內容裡重複了標題")
        XCTAssertFalse(app.staticTexts["Chat and terminal are free and never need a subscription."].exists, "頁首仍有說明文字")

        let yearly = app.descendants(matching: .any)[Self.yearly].firstMatch
        XCTAssertTrue(yearly.waitUntilExists(timeout: 15))
        yearly.press(forDuration: 0.3)
        XCTAssertTrue(yearly.isSelected || yearly.value as? String == "Selected", "\(String(describing: yearly.value))")
        let disclosure = app.staticTexts["plus.disclosure"]
        app.scrollIntoView(disclosure, search: .down)
        XCTAssertTrue(disclosure.label.contains("$39.99"), disclosure.label)
        XCTAssertTrue(disclosure.label.contains("year"), disclosure.label)
    }

    /// 已訂閱(#323):方案區塊有「管理訂閱」,「你的 Plus 包含」逐項帶目前狀態,點了到帳號頁;不再只有一張卡片。
    @MainActor
    func testSubscribedPageListsFeaturesWithStatus() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        openPlus(in: app)

        XCTAssertTrue(app.buttons["plus.manage"].waitUntilExists(timeout: 15), "沒有管理訂閱")
        XCTAssertTrue(app.staticTexts["plus.summary"].exists)
        for feature in ["notifications", "hostSync", "devices"] {
            let row = app.descendants(matching: .any)["plus.feature.\(feature)"].firstMatch
            app.scrollIntoView(row, search: .down)
            XCTAssertTrue(row.exists, "沒有 \(feature) 功能列")
        }
        let notifications = app.descendants(matching: .any)["plus.feature.notifications"].firstMatch
        XCTAssertTrue(notifications.label.contains("Off"), "還沒開通知時列尾該是關閉:\(notifications.label)")
        // 直接開 Plus 頁(沒先開過帳號頁)列尾也要有通知裝置數:頁面自己讀清單。
        let devices = app.descendants(matching: .any)["plus.feature.devices"].firstMatch
        let devicesCount = NSPredicate(format: "label CONTAINS 'device'")
        XCTAssertTrue(devices.wait(for: devicesCount, timeout: 10), "等待的條件沒有成立")
        XCTAssertTrue(app.descendants(matching: .any)["plus.free"].firstMatch.exists, "沒有「不需要訂閱」")

        // 已訂閱時不顯示恢復購買與兌換代碼(#325);往下捲到條款,確認整頁都沒有。
        app.scrollIntoView(app.descendants(matching: .any)["plus.terms"].firstMatch, search: .down)
        XCTAssertFalse(app.descendants(matching: .any)["plus.restore"].firstMatch.exists, "已訂閱不該有恢復購買")
        XCTAssertFalse(app.descendants(matching: .any)["plus.redeem"].firstMatch.exists, "已訂閱不該有兌換代碼")
        XCTAssertTrue(app.scrollIntoView(notifications, search: .up, limit: 8), "捲不回通知功能列")

        notifications.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sheet.account"].firstMatch.waitUntilExists(timeout: 10), "點功能列沒有到帳號頁")
    }


    @MainActor
    private func openPlus(in app: XCUIApplication) {
        app.openPlusPaywall()
    }

}
