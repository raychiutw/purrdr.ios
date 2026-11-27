import XCTest

/// 付費牆(HIG 檢核清單 20.12)。商品來自 scheme 指定的 StoreKit 設定檔 `src/App/Purrdr.storekit`(不連 App Store)。
final class PlusUITests: XCTestCase {
    static let monthly = "plus.plan.com.raychiu.purrdr.plus.monthly"
    static let yearly = "plus.plan.com.raychiu.purrdr.plus.yearly"

    override func setUp() {
        continueAfterFailure = false
    }

    /// 每個方案揭露名稱、期間、每期內容、當地幣別的完整價格、試用後自動扣款;另有恢復購買、兌換代碼、條款與隱私權政策。
    /// 預設字級那次啟動(AX 最大字級的付費牆揭露在 `SignInUITests` 的 AX 啟動裡):頁首只有標題(#236);預設年繳、年繳在前;
    /// 改選月繳時說明換成月繳的價格,方案卡片有按壓回饋後(#234)按住一下再放開仍選取該方案。
    /// 訂閱要先成為會員(權限記在會員身上):沒登入時主要按鈕帶去登入。付費牆可以關閉、不擋免費功能。
    /// 最後回到列表,接著同一次啟動驗登入頁(預設字級):Sign in with Apple 按鈕的量測、標題與簡短說明(#328,原型 A)、不放舊版的功能說明文字。
    @MainActor
    func testPaywallDisclosuresAtDefaultSizeSubscribingNeedsSignInThenSignInPage() {
        let app = XCUIApplication.launchUITesting()
        openPlus(in: app)
        let benefits = app.descendants(matching: .any)["plus.benefits"].firstMatch
        XCTAssertTrue(benefits.waitUntilExists(timeout: 15), "沒有每期內容(預設字級)")

        Self.assertPaywallDisclosures(in: app, size: "預設字級", selectedPrice: "$39.99")

        // 預設字級那一輪再驗。
        let monthly = app.descendants(matching: .any)[Self.monthly].firstMatch
        let yearly = app.descendants(matching: .any)[Self.yearly].firstMatch
        let disclosure = app.staticTexts["plus.disclosure"]
        app.scrollIntoView(benefits, search: .up)
        XCTAssertFalse(app.scrollViews.staticTexts["Purrdr Plus"].exists, "內容裡重複了標題")
        XCTAssertFalse(app.staticTexts["Chat and terminal are free and never need a subscription."].exists, "頁首仍有說明文字")
        app.scrollIntoView(yearly, search: .down)
        XCTAssertTrue(yearly.isSelected || yearly.value as? String == "Selected", "預設沒選年繳:\(String(describing: yearly.value))")
        XCTAssertLessThan(yearly.frame.minY, monthly.frame.minY, "年繳沒有排在月繳前面")
        app.scrollIntoView(monthly, search: .up)
        monthly.press(forDuration: 0.3)
        XCTAssertTrue(monthly.wait(for: NSPredicate(format: "isSelected == true OR value == 'Selected'"), timeout: 5), "\(String(describing: monthly.value))")
        app.scrollIntoView(disclosure, search: .down)
        XCTAssertTrue(disclosure.label.contains("$4.99"), disclosure.label)

        app.scrollIntoView(benefits, search: .up)
        let subscribe = app.buttons["plus.subscribe"]
        XCTAssertTrue(app.scrollIntoView(subscribe, search: .both, timeout: 15))
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
        XCTAssertTrue(app.descendants(matching: .any)["spaces.tab.demo/w2:t1"].firstMatch.waitUntilExists(timeout: 5))

        // 登入頁(預設字級):同樣的按鈕量測,加上標題與簡短說明、不放舊版的功能說明文字。
        app.openSignInFromAccount()
        SignInUITests.assertSignInButtons(in: app, label: "預設字級")
        XCTAssertTrue(app.staticTexts["Sign In to Purrdr"].exists, "沒有標題")
        let description = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "A member account is only needed", "never need an account"))
        XCTAssertEqual(description.count, 0, "登入頁仍有說明文字")
    }

    @MainActor
    static func assertPaywallDisclosures(in app: XCUIApplication, size: String, selectedPrice: String) {
        // 每期內容在最上面(App Store 3.1.2);大字級時方案在畫面外,下面再捲過去。
        let benefits = app.descendants(matching: .any)["plus.benefits"].firstMatch
        app.scrollIntoView(benefits, search: .up)
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
        // 預設選年繳(完整扣款揭露保留)。
        XCTAssertTrue(disclosure.label.contains(selectedPrice), disclosure.label)
        XCTAssertTrue(disclosure.label.contains("renews automatically"), disclosure.label)
        XCTAssertTrue(disclosure.label.contains("24 hours"), disclosure.label)

        for identifier in ["plus.restore", "plus.redeem", "plus.terms", "plus.privacy"] {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            app.scrollIntoView(element, search: .down)
            XCTAssertTrue(element.isHittable, "\(identifier) 點不到(\(size))")
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(identifier) 觸控目標太小(\(size))")
        }
    }

    /// 已訂閱(#323):方案區塊有「管理訂閱」,「你的 Plus 包含」逐項帶目前狀態,點了到帳號頁;不再只有一張卡片。
    /// 通知列尾是 Off 必須在開通知之前驗,所以通知頁的測試通知放在推入通知頁之後(`-uiTestingPushTestFails` 只改測試通知的結果):
    /// 測試通知的結果直接寫在列下方、不彈 alert(#625、#626),失敗是紅色三角說明(成功的說明文字由 PushModelTests 守)。
    @MainActor
    func testSubscribedPageListsFeaturesWithStatusAndTestNotificationResultIsInline() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost", "-uiTestingPushTestFails"])
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
        // 往右 push 對應的頁面(#619),不換成帳號 sheet。
        XCTAssertTrue(app.descendants(matching: .any)["account.notifications.page"].firstMatch.waitUntilExists(timeout: 10), "點功能列沒有推入通知頁")
        XCTAssertFalse(app.descendants(matching: .any)["sheet.account"].firstMatch.exists, "點功能列不該換成帳號 sheet")
        XCTAssertTrue(app.buttons["BackButton"].firstMatch.exists, "左上沒有返回鈕")

        // 通知頁:開 Studio Mac 的開關(先確認安裝外掛),傳送測試通知,結果在頁內、不彈 alert。
        let toggle = app.switches["account.push.\(PushSettingsUITests.seededHost)"]
        XCTAssertTrue(toggle.waitUntilExists(timeout: 10), "沒有主機的通知開關")
        toggle.tap()
        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitUntilExists(timeout: 10), "沒有先確認安裝外掛")
        install.tap()
        toggle.expectValue("Notifications On")
        let test = app.buttons["account.push.\(PushSettingsUITests.seededHost).test"].firstMatch
        XCTAssertTrue(test.waitUntilExists(timeout: 10), "開啟後沒有「Send Test Notification」")
        test.tap()
        let result = app.descendants(matching: .any)["account.push.\(PushSettingsUITests.seededHost).test.result"].firstMatch
        XCTAssertTrue(result.waitUntilExists(timeout: 10), "測試通知沒有頁內結果")
        XCTAssertFalse(app.alerts.firstMatch.exists, "測試通知結果不該彈 alert")

        app.buttons["BackButton"].firstMatch.tap()
        let devices2 = app.descendants(matching: .any)["plus.feature.devices"].firstMatch
        XCTAssertTrue(app.scrollIntoView(devices2, search: .down, limit: 8), "返回後沒有回到 Plus 頁")
        devices2.tap()
        XCTAssertTrue(app.descendants(matching: .any)["account.pushDevices"].firstMatch.waitUntilExists(timeout: 10), "點通知裝置沒有推入裝置頁")
    }


    @MainActor
    private func openPlus(in app: XCUIApplication) {
        app.openPlusPaywall()
    }

}
