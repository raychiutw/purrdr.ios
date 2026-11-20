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
        XCTAssertFalse(app.buttons["This Device’s Key"].exists, "Tailscale SSH 不該有登入方式")
        XCTAssertFalse(app.secureTextFields["hostEditor.password"].exists, "Tailscale SSH 不該有密碼")

        choose("openSSH", in: app)
        XCTAssertEqual(field("port", in: app).value as? String, "22")
        // 登入方式攤開成勾選列(#313)。
        let signIn = app.buttons["This Device’s Key"]
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
        port.typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "8443")
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
        code.typeEnglish("K7QM-2XPA")
        XCTAssertEqual(code.value as? String, "K7QM-2XPA")
    }

    /// 輸入值靠左，尾端空白保留在欄位裡(靠右時會被吃掉、看不見)。
    @MainActor
    func testTrailingSpacesStayInField() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        let name = field("name", in: app)
        name.tap()
        name.typeEnglish("Studio  ")

        XCTAssertEqual(name.value as? String, "Studio  ")
        XCTAssertLessThan(name.frame.minX, app.windows.firstMatch.frame.midX, "輸入框沒有緊接在標籤後")
    }

    // MARK: - 收鍵盤(#312)

    /// 密碼登入：輸入密碼後按鍵盤上方的「完成」收起鍵盤，下面的「測試連線」點得到。
    @MainActor
    func testDoneDismissesKeyboardAfterPassword() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        choose("openSSH", in: app)
        let passwordMethod = app.buttons["Password"]
        XCTAssertTrue(passwordMethod.exists || scrollTo(passwordMethod, in: app), "沒有密碼登入")
        passwordMethod.tap()

        let password = app.secureTextFields["hostEditor.password"]
        XCTAssertTrue(scrollTo(password, in: app), "沒有密碼欄")
        password.tap()
        password.typeEnglish("hunter2")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "沒有出現軟體鍵盤")

        tapKeyboardDone(app)

        XCTAssertTrue(waitForKeyboardToHide(app), "按「完成」後鍵盤沒有收起")
        let test = app.buttons["hostEditor.test"]
        XCTAssertTrue(scrollTo(test, in: app) && test.isHittable, "鍵盤收起後「Test Connection」點不到")
    }

    /// 連接埠是數字鍵盤(沒有 return):「完成」一樣收得起來。
    @MainActor
    func testDoneDismissesNumberPad() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        choose("tailscaleSSH", in: app)
        let port = field("port", in: app)
        port.tap()
        port.typeText("0")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "沒有出現數字鍵盤")

        tapKeyboardDone(app)

        XCTAssertTrue(waitForKeyboardToHide(app), "數字鍵盤按「完成」後沒有收起")
    }

    /// 單行欄位按 return 跳到下一個欄位;最後一個欄位按 return 收起鍵盤。
    @MainActor
    func testReturnMovesToNextFieldThenDismisses() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        choose("https", in: app)
        let address = field("address", in: app)
        address.tap()
        address.typeEnglish("studio.tail1234.ts.net\n")

        XCTAssertTrue(hasKeyboardFocus(field("port", in: app)), "位址欄按 return 沒有移到 Port")

        let code = field("pairingCode", in: app)
        code.tap()
        code.typeEnglish("K7QM-2XPA\n")
        XCTAssertTrue(waitForKeyboardToHide(app), "最後一個欄位(配對碼)按 return 沒有收起鍵盤")
    }

    /// 往下捲表單(看下面的欄位與按鈕)時鍵盤收起。
    @MainActor
    func testScrollingFormDismissesKeyboard() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        choose("openSSH", in: app)
        let username = field("username", in: app)
        username.tap()
        username.typeEnglish("ray")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "沒有出現軟體鍵盤")

        // 從表單左側留白往上拖(不從輸入框開始，免得拖成選取文字)。
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.55)).press(
            forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.15)))

        XCTAssertTrue(waitForKeyboardToHide(app), "捲動表單後鍵盤沒有收起")
    }

    /// 用密碼加入公鑰：密碼欄輸入後收起鍵盤，「Add Key Using Password」點得到;密碼欄不跳強密碼建議。
    @MainActor
    func testKeyInstallPasswordDismissesKeyboard() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        choose("openSSH", in: app)
        for (identifier, text) in [("name", "Studio"), ("address", "studio"), ("username", "ray")] {
            let element = field(identifier, in: app)
            element.tap()
            element.typeEnglish(text)
        }
        let password = app.secureTextFields["hostEditor.keyInstallPassword"]
        XCTAssertTrue(scrollTo(password, in: app), "沒有加入公鑰的密碼欄")
        password.tap()
        password.typeEnglish("hunter2")
        XCTAssertFalse(app.buttons["Use Strong Password"].exists, "跳出了強密碼建議")

        tapKeyboardDone(app)

        XCTAssertTrue(waitForKeyboardToHide(app), "加入公鑰的密碼欄按「完成」後鍵盤沒有收起")
        let install = app.buttons["hostEditor.installKey"]
        XCTAssertTrue(scrollTo(install, in: app) && install.isHittable && install.isEnabled, "「Add Key Using Password」點不到")
    }

    // MARK: - 輔助

    @MainActor
    private func tapKeyboardDone(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["hostEditor.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "鍵盤上方沒有「完成」", file: file, line: line)
        XCTAssertEqual(done.label, "Done", file: file, line: line)
        done.tap()
    }

    @MainActor
    private func waitForKeyboardToHide(_ app: XCUIApplication) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        return XCTWaiter().wait(for: [gone], timeout: 3) == .completed
    }

    @MainActor
    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element)
        return XCTWaiter().wait(for: [focused], timeout: 3) == .completed
    }


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
