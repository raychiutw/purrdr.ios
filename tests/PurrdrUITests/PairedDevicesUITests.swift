import XCTest

/// 主機頁(ⓘ)下方的已配對裝置(#291)。UI 測試替身：這支 iPhone 與另一支唯讀的 iPad。
final class PairedDevicesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 滑動別支裝置「撤銷」→ 確認後從列表消失;這支裝置沒有撤銷動作。
    @MainActor
    func testRevokeOtherDeviceAfterConfirmation() {
        let app = XCUIApplication.launchUITesting()
        addHTTPSHost(app, code: "K7QM-2XPA")
        openStatus(app)

        let otherDevice = app.descendants(matching: .any)["pairedDevices.row.ui-testing-ipad"].firstMatch
        XCTAssertTrue(otherDevice.waitForExistence(timeout: 10) || scrollTo(otherDevice, in: app), "沒有另一支裝置")
        let thisDevice = app.descendants(matching: .any)["pairedDevices.row.ui-testing"].firstMatch
        XCTAssertTrue(thisDevice.label.contains("This Device"), thisDevice.label)

        thisDevice.swipeLeft()
        XCTAssertFalse(app.buttons["Revoke"].waitForExistence(timeout: 2), "這支裝置不該能在列表撤銷")

        otherDevice.swipeLeft()
        let revoke = app.buttons["Revoke"]
        XCTAssertTrue(revoke.waitForExistence(timeout: 5), "沒有撤銷鈕")
        revoke.tap()
        let confirm = app.buttons["pairedDevices.confirmRevoke"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "沒有確認對話框")
        XCTAssertTrue(otherDevice.exists, "確認前就撤銷了")
        confirm.tap()

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: otherDevice)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "撤銷後還在列表")
    }

    /// 「這支裝置」滑動是「移除主機」:回到主機清單跳出移除主機的確認(撤銷自己沿用移除主機流程)。
    @MainActor
    func testThisDeviceRowOpensHostRemoval() {
        let app = XCUIApplication.launchUITesting()
        addHTTPSHost(app, code: "K7QM-2XPA")
        openStatus(app)

        let thisDevice = app.descendants(matching: .any)["pairedDevices.row.ui-testing"].firstMatch
        XCTAssertTrue(thisDevice.waitForExistence(timeout: 10) || scrollTo(thisDevice, in: app), "沒有這支裝置")
        thisDevice.swipeLeft()
        let remove = app.buttons["pairedDevices.removeHost"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "這支裝置沒有移除主機")
        remove.tap()

        XCTAssertTrue(app.buttons["hosts.delete.confirm"].waitForExistence(timeout: 5), "沒有移除主機的確認")
    }

    /// 唯讀裝置(啟動時已用唯讀權杖配對):看得到列表，沒有撤銷動作並說明原因。
    @MainActor
    func testReadOnlyDeviceOnlyViews() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedReadOnlyHTTPSHost"])
        openStatus(app)

        let otherDevice = app.descendants(matching: .any)["pairedDevices.row.ui-testing-ipad"].firstMatch
        XCTAssertTrue(otherDevice.waitForExistence(timeout: 10) || scrollTo(otherDevice, in: app), "沒有另一支裝置")
        XCTAssertTrue(
            app.staticTexts["This device is paired read-only, so it can’t revoke devices."].exists
                || scrollTo(app.staticTexts["This device is paired read-only, so it can’t revoke devices."], in: app),
            "沒有說明唯讀")
        otherDevice.swipeLeft()
        XCTAssertFalse(app.buttons["Revoke"].waitForExistence(timeout: 2), "唯讀裝置不該能撤銷")
    }

    @MainActor
    private func addHTTPSHost(_ app: XCUIApplication, code: String) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["menu.hosts"].tap()
        let add = app.buttons["hosts.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let https = app.buttons["hostEditor.method.https"]
        XCTAssertTrue(https.waitForExistence(timeout: 5) || scrollTo(https, in: app), "沒有 HTTPS 連線方式")
        https.tap()
        app.swipeDown()
        for (identifier, text) in [("name", "Studio"), ("address", "studio.tail1234.ts.net"), ("pairingCode", code)] {
            let field = app.textFields["hostEditor.\(identifier)"]
            XCTAssertTrue(scrollTo(field, in: app), "沒有 \(identifier) 欄位")
            field.tap()
            field.typeEnglish(text)
        }
        let test = app.buttons["hostEditor.test"]
        XCTAssertTrue(test.exists || scrollTo(test, in: app))
        test.tap()
        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label CONTAINS %@", "Connected", "Read-only"))
            .firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 10) || scrollTo(connected, in: app), "沒有連上")
        app.buttons["hostEditor.save"].tap()
    }

    @MainActor
    private func openStatus(_ app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["menu.hosts"].tap()
        // 主機狀態區塊在主機頁(列尾 ⓘ)最下方。
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "hosts.info.", "Studio")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5), "主機清單沒有 Studio")
        info.tap()
        XCTAssertTrue(app.buttons["hostEditor.save"].waitForExistence(timeout: 5), "沒有開啟主機頁")
        for _ in 0..<6 {
            app.swipeUp()
        }
    }

    /// 捲到元素出現且不在鍵盤底下(表單比畫面長):先往下，沒有再往上。
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let keyboard = app.keyboards.firstMatch
        func isReachable() -> Bool {
            element.isHittable && (!keyboard.exists || element.frame.maxY < keyboard.frame.minY)
        }
        for _ in 0..<6 where !isReachable() {
            app.swipeUp()
        }
        for _ in 0..<6 where !isReachable() {
            app.swipeDown()
        }
        return element.exists
    }
}
