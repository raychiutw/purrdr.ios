import XCTest

/// 加入主機頁(#250):先選連線方式、各方式只出現自己的欄位、Port 預設、配對 QR code 掃描(以 launch 旗標模擬，不用真相機)。
final class AddHostUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 三種連線方式各自的欄位：Tailscale SSH 沒有密碼與登入方式，OpenSSH 多登入方式，HTTPS 沒有帳號、有配對碼;Port 跟著換預設。
    @MainActor
    func testEachMethodShowsOnlyItsFields() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        XCTAssertFalse(app.textFields["hostEditor.port"].exists, "還沒選連線方式就出現 Port")

        choose("tailscaleSSH", in: app)
        XCTAssertEqual(field("port", in: app).value as? String, "22")
        XCTAssertTrue(field("username", in: app).exists)
        XCTAssertFalse(app.buttons["hostEditor.signIn"].exists, "Tailscale SSH 不該有登入方式")
        XCTAssertFalse(app.secureTextFields["hostEditor.password"].exists, "Tailscale SSH 不該有密碼")

        choose("openSSH", in: app)
        XCTAssertEqual(field("port", in: app).value as? String, "22")
        let signIn = app.buttons["hostEditor.signIn"]
        XCTAssertTrue(signIn.exists || scrollTo(signIn, in: app), "OpenSSH 沒有登入方式")

        choose("https", in: app)
        XCTAssertEqual(field("port", in: app).value as? String, "443")
        XCTAssertFalse(app.textFields["hostEditor.username"].exists, "HTTPS 不該有帳號")
        XCTAssertTrue(field("pairingCode", in: app).exists)
    }

    /// 手動改過的 Port 換連線方式不覆蓋。
    @MainActor
    func testEditedPortSurvivesMethodChange() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        choose("https", in: app)
        let port = field("port", in: app)
        // 輸入值靠左，點欄位中間時游標在「443」之後。
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "8443")
        XCTAssertEqual(port.value as? String, "8443")

        choose("openSSH", in: app)

        XCTAssertEqual(field("port", in: app).value as? String, "8443")
    }

    /// 配對碼右邊的掃描鈕開相機掃描;掃到配對 QR code 後自動選 HTTPS 並填好位址、Port、配對碼。
    @MainActor
    func testScanningPairingCodeFillsFields() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPairingScan"])
        openAddHost(app)
        choose("https", in: app)

        let scan = app.buttons["hostEditor.scanPairingCode"]
        XCTAssertTrue(scan.exists || scrollTo(scan, in: app), "配對碼旁沒有掃描鈕")
        XCTAssertEqual(scan.label, "Scan QR Code")
        scan.tap()

        let viewfinder = app.descendants(matching: .any)["scanner.viewfinder"]
        XCTAssertTrue(viewfinder.waitForExistence(timeout: 5), "沒有開掃描畫面")
        XCTAssertTrue(app.buttons["scanner.manual"].exists, "掃描畫面沒有改手動輸入")
        XCTAssertTrue(app.buttons["hostEditor.scanPairingCode"].waitForExistence(timeout: 10), "掃到後沒有回到加入主機")
        XCTAssertEqual(field("pairingCode", in: app).value as? String, "K7QM-2XPA")
        XCTAssertEqual(field("address", in: app).value as? String, "studio.tail1234.ts.net")
        XCTAssertEqual(field("port", in: app).value as? String, "8443")
        XCTAssertEqual(field("name", in: app).value as? String, "studio")
    }

    /// 沒有相機權限：說明並可改手動輸入，配對碼欄位仍可輸入。
    @MainActor
    func testCameraDeniedExplainsAndKeepsManualEntry() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingCameraDenied"])
        openAddHost(app)
        choose("https", in: app)
        let scan = app.buttons["hostEditor.scanPairingCode"]
        XCTAssertTrue(scan.exists || scrollTo(scan, in: app))
        scan.tap()

        let denied = app.descendants(matching: .any)["scanner.denied"]
        XCTAssertTrue(denied.waitForExistence(timeout: 5), "沒有說明相機權限")
        app.buttons["scanner.manual"].firstMatch.tap()

        let code = field("pairingCode", in: app)
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("K7QM-2XPA")
        XCTAssertEqual(code.value as? String, "K7QM-2XPA")
    }

    /// 輸入值靠左，尾端空白保留在欄位裡(靠右時會被吃掉、看不見)。
    @MainActor
    func testTrailingSpacesStayInField() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        let name = field("name", in: app)
        name.tap()
        name.typeText("Studio  ")

        XCTAssertEqual(name.value as? String, "Studio  ")
        XCTAssertLessThan(name.frame.minX, app.windows.firstMatch.frame.midX, "輸入框沒有緊接在標籤後")
    }

    // MARK: - 輔助

    @MainActor
    private func openAddHost(_ app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["menu.hosts"].tap()
        let add = app.buttons["hosts.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.textFields["hostEditor.name"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func choose(_ method: String, in app: XCUIApplication) {
        app.swipeDown()
        let card = app.buttons["hostEditor.method.\(method)"]
        XCTAssertTrue(card.waitForExistence(timeout: 5) || scrollTo(card, in: app), "沒有 \(method) 連線方式")
        card.tap()
        XCTAssertTrue(card.isSelected, "\(method) 沒有標成已選")
    }

    @MainActor
    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.textFields["hostEditor.\(identifier)"]
        _ = element.exists || scrollTo(element, in: app)
        return element
    }

    /// 捲到元素出現(表單比畫面長):先往下，沒有再往上。
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp()
        }
        // 已捲過頭(例如掃描後回到表單下半部，名稱在上面):往回捲。
        for _ in 0..<6 where !element.isHittable {
            app.swipeDown()
        }
        return element.exists
    }
}
