import XCTest

/// 新增主機引導的輸入與鍵盤(#250、#312、#341):沒有相機權限時改手動輸入、收鍵盤(完成、return、捲動),
/// 以及原生 SSH 的密碼欄。連線方式與欄位流程的整條路徑在 `AddHostGuideUITests`。
final class AddHostUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 沒有相機權限：說明並可改手動輸入，配對碼欄位仍可輸入。
    @MainActor
    func testCameraDeniedExplainsAndKeepsManualEntry() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingCameraDenied"])
        openPairStep(app)
        app.buttons["guide.scan"].tapWhenReady()

        let denied = app.descendants(matching: .any)["scanner.denied"]
        XCTAssertTrue(denied.waitForExistence(timeout: 5), "沒有說明相機權限")
        app.buttons["scanner.manual"].firstMatch.tap()

        app.buttons["Enter It Manually"].firstMatch.tapWhenReady()
        let code = app.textFields["guide.field.pairingCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeEnglish("K7QM-2XPA")
        XCTAssertEqual(code.value as? String, "K7QM-2XPA")
    }

    // MARK: - 收鍵盤(#312)

    /// 密碼登入：輸入密碼後按鍵盤上方的「完成」收起鍵盤，下面的「下一步」點得到。
    @MainActor
    func testDoneDismissesKeyboardAfterPassword() {
        let app = XCUIApplication.launchUITesting()
        openNativeSSHLogin(app)
        app.buttons["guide.option.password"].tapWhenReady()

        let password = app.secureTextFields["guide.field.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5), "沒有密碼欄")
        password.tap()
        password.typeEnglish("hunter2")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "沒有出現軟體鍵盤")

        tapKeyboardDone(app)

        XCTAssertTrue(waitForKeyboardToHide(app), "按「完成」後鍵盤沒有收起")
        XCTAssertTrue(app.buttons["guide.next"].isHittable, "鍵盤收起後「Next」點不到")
    }

    /// 連接埠是數字鍵盤(沒有 return):「完成」一樣收得起來。
    @MainActor
    func testDoneDismissesNumberPad() {
        let app = XCUIApplication.launchUITesting()
        openTailscaleDetails(app)
        let port = app.textFields["guide.field.port"]
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
        openPairStep(app)
        app.buttons["Enter It Manually"].firstMatch.tapWhenReady()
        let address = app.textFields["guide.field.pairAddress"]
        address.tapWhenReady()
        address.typeEnglish("studio.tail1234.ts.net\n")

        XCTAssertTrue(hasKeyboardFocus(app.textFields["guide.field.pairPort"]), "位址欄按 return 沒有移到 Port")

        let code = app.textFields["guide.field.pairingCode"]
        code.tap()
        code.typeEnglish("K7QM-2XPA\n")
        XCTAssertTrue(waitForKeyboardToHide(app), "最後一個欄位(配對碼)按 return 沒有收起鍵盤")
    }

    /// 匯入私鑰是多行輸入(沒有 return):鍵盤上方的「完成」收得起來。
    @MainActor
    func testDoneDismissesKeyboardAfterPrivateKey() {
        let app = XCUIApplication.launchUITesting()
        openNativeSSHLogin(app)
        app.buttons["guide.otherWays"].tapWhenReady()
        app.buttons["guide.option.importedKey"].tapWhenReady()

        let key = app.textViews["guide.field.privateKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "沒有私鑰欄")
        key.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "沒有出現軟體鍵盤")

        tapKeyboardDone(app)

        XCTAssertTrue(waitForKeyboardToHide(app), "私鑰欄按「完成」後鍵盤沒有收起")
    }

    // MARK: - 輔助

    @MainActor
    private func tapKeyboardDone(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["guide.keyboardDone"]
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
    private func openGuide(_ app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["menu.hosts"].tap()
        let add = app.buttons["hosts.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.buttons["guide.option.ssh"].waitForExistence(timeout: 5), "沒有開出新增主機引導")
    }

    /// HTTPS 路徑到配對那一頁。
    @MainActor
    private func openPairStep(_ app: XCUIApplication) {
        openGuide(app)
        app.buttons["guide.option.https"].tap()
        app.buttons["guide.next"].tapWhenReady()
        app.buttons["guide.option.linux"].tapWhenReady()
        app.buttons["guide.next"].tapWhenReady()
        XCTAssertTrue(app.buttons["guide.scan"].waitForExistence(timeout: 5), "沒有到配對那一頁")
    }

    /// Tailscale SSH 路徑到填主機那一頁(位址、Port、帳號)。
    @MainActor
    private func openTailscaleDetails(_ app: XCUIApplication) {
        openGuide(app)
        app.buttons["guide.option.ssh"].tap()
        app.buttons["guide.option.macOS"].tapWhenReady()
        app.buttons["guide.option.tailscale"].tapWhenReady()
        app.buttons["guide.next"].tapWhenReady()
        XCTAssertTrue(app.textFields["guide.field.port"].waitForExistence(timeout: 5), "沒有到填主機那一頁")
    }

    /// 原生 SSH 路徑到選登入方式那一頁。
    @MainActor
    private func openNativeSSHLogin(_ app: XCUIApplication) {
        openGuide(app)
        app.buttons["guide.option.ssh"].tap()
        app.buttons["guide.option.macOS"].tapWhenReady()
        app.buttons["guide.option.native"].tapWhenReady()
        app.buttons["guide.next"].tapWhenReady()
        app.buttons["guide.option.home"].tapWhenReady()
        let address = app.textFields["guide.field.address"]
        address.tapWhenReady()
        address.typeEnglish("192.168.1.20")
        let username = app.textFields["guide.field.username"]
        username.tap()
        username.typeEnglish("ray")
        app.buttons["guide.next"].tap()
        XCTAssertTrue(app.buttons["guide.option.password"].waitForExistence(timeout: 5), "沒有到選登入方式那一頁")
    }
}

private extension XCUIElement {
    /// 等元素出現(換頁動畫)再點。
    @MainActor
    func tapWhenReady() {
        XCTAssertTrue(waitForExistence(timeout: 5), "\(identifier) 沒有出現")
        tap()
    }
}
