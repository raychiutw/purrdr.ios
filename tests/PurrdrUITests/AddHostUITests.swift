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
        XCTAssertTrue(denied.waitUntilExists(timeout: 5), "沒有說明相機權限")
        app.buttons["scanner.manual"].firstMatch.tap()
        // 掃描畫面收起的動畫還在跑時點輸入框,焦點會被收起的 sheet 搶走:等它離開再繼續。
        XCTAssertTrue(denied.waitUntilGone(timeout: 5), "掃描畫面沒有收起")

        app.buttons["Enter It Manually"].firstMatch.tapWhenReady()
        let code = app.textFields["guide.field.pairingCode"]
        XCTAssertTrue(code.waitUntilExists(timeout: 5))
        // 展開後頁面自己捲到欄位在底部面板上方(不然點到面板的「掃描」):等捲完再點。
        let panel = app.descendants(matching: .any)["guide.panel"].firstMatch
        XCTAssertTrue(UITestWait.until(timeout: 5) { code.frame.maxY < panel.frame.minY }, "配對碼欄位被底部面板蓋住:\(code.frame) \(panel.frame)")
        code.tap()
        code.typeEnglish("K7QM-2XPA")
        XCTAssertEqual(code.value as? String, "K7QM-2XPA")
    }

    // MARK: - 收鍵盤(#312)

    /// 收鍵盤(#312,同一次啟動,原本 4 個測試合併;各段之間以系統返回回到引導第一頁再走另一條路徑):
    /// 密碼欄與匯入私鑰(多行輸入、沒有 return)輸入後按鍵盤上方的「完成」都收得起來,密碼那一輪還要確認下面的「下一步」點得到;
    /// 連接埠的數字鍵盤按「完成」收起;單行欄位按 return 跳到下一個欄位、最後一個欄位按 return 收起。
    @MainActor
    func testKeyboardDismissesAfterPasswordPrivateKeyNumberPadAndReturnOnPairFields() {
        let app = XCUIApplication.launchUITesting()
        openNativeSSHLogin(app)
        app.buttons["guide.option.password"].tapWhenReady()

        let password = app.secureTextFields["guide.field.password"]
        XCTAssertTrue(password.waitUntilExists(timeout: 5), "沒有密碼欄")
        password.tap()
        password.typeEnglish("hunter2")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "沒有出現軟體鍵盤")

        tapKeyboardDone(app)

        XCTAssertTrue(app.waitForKeyboardToHide(), "按「完成」後鍵盤沒有收起")
        XCTAssertTrue(app.buttons["guide.next"].isHittable, "鍵盤收起後「Next」點不到")

        // 回上一步(左上系統返回鈕)到選登入方式那一頁,再選私鑰。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["guide.option.password"].waitUntilExists(timeout: 5), "返回後沒有回到選登入方式那一頁")
        app.buttons["Other Ways"].firstMatch.tapWhenReady()  // 系統 DisclosureGroup 的展開鈕(#622)
        app.buttons["guide.option.importedKey"].tapWhenReady()

        let key = app.textViews["guide.field.privateKey"]
        XCTAssertTrue(key.waitUntilExists(timeout: 5), "沒有私鑰欄")
        key.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "沒有出現軟體鍵盤")

        tapKeyboardDone(app)

        XCTAssertTrue(app.waitForKeyboardToHide(), "私鑰欄按「完成」後鍵盤沒有收起")

        // 連接埠是數字鍵盤(沒有 return):「完成」一樣收得起來(回到引導第一頁再走 Tailscale SSH 路徑)。
        returnToGuideStart(app)
        openTailscaleDetails(app)
        let port = app.textFields["guide.field.port"]
        port.tap()
        port.typeText("0")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "沒有出現數字鍵盤")

        tapKeyboardDone(app)

        XCTAssertTrue(app.waitForKeyboardToHide(), "數字鍵盤按「完成」後沒有收起")

        // 單行欄位按 return 跳到下一個欄位;最後一個欄位按 return 收起鍵盤(回到引導第一頁再走 HTTPS 路徑)。
        returnToGuideStart(app)
        openPairStep(app)
        app.buttons["Enter It Manually"].firstMatch.tapWhenReady()
        let address = app.textFields["guide.field.pairAddress"]
        address.tapWhenReady()
        address.typeEnglish("studio.tail1234.ts.net\n")

        XCTAssertTrue(app.textFields["guide.field.pairPort"].wait(timeout: 3) { ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true }, "位址欄按 return 沒有移到 Port")

        let code = app.textFields["guide.field.pairingCode"]
        code.tap()
        code.typeEnglish("K7QM-2XPA\n")
        XCTAssertTrue(app.waitForKeyboardToHide(), "最後一個欄位(配對碼)按 return 沒有收起鍵盤")
    }

    // MARK: - 輔助

    @MainActor
    private func tapKeyboardDone(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["guide.keyboardDone"]
        XCTAssertTrue(done.waitUntilExists(timeout: 3), "鍵盤上方沒有「完成」", file: file, line: line)
        XCTAssertEqual(done.label, "Done", file: file, line: line)
        done.tap()
    }

    /// 在引導較深的一頁時按系統返回,回到第一頁(選連線方式)。
    @MainActor
    private func returnToGuideStart(_ app: XCUIApplication) {
        for _ in 0..<8 where !app.buttons["guide.option.ssh"].isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = app.buttons["guide.option.ssh"].waitUntilHittable(timeout: 1)
        }
        XCTAssertTrue(app.buttons["guide.option.ssh"].isHittable, "沒有回到引導第一頁")
    }

    @MainActor
    private func openGuide(_ app: XCUIApplication) {
        // 已經在引導第一頁(例如上一段剛返回)就不用再開。
        if app.buttons["guide.option.ssh"].isHittable { return }
        app.openHostsTab()
        let add = app.buttons["hosts.add"]
        XCTAssertTrue(add.waitUntilExists(timeout: 5))
        add.tap()
        XCTAssertTrue(app.buttons["guide.option.ssh"].waitUntilExists(timeout: 5), "沒有開出新增主機引導")
    }

    /// HTTPS 路徑到配對那一頁。
    @MainActor
    private func openPairStep(_ app: XCUIApplication) {
        openGuide(app)
        app.buttons["guide.option.https"].tap()
        app.buttons["guide.next"].tapWhenReady()
        app.buttons["guide.option.linux"].tapWhenReady()
        app.buttons["guide.next"].tapWhenReady()
        XCTAssertTrue(app.buttons["Enter It Manually"].firstMatch.waitUntilExists(timeout: 5), "沒有到配對那一頁")
    }

    /// Tailscale SSH 路徑到填主機那一頁(位址、Port、帳號)。
    @MainActor
    private func openTailscaleDetails(_ app: XCUIApplication) {
        openGuide(app)
        app.buttons["guide.option.ssh"].tap()
        app.buttons["guide.option.macOS"].tapWhenReady()
        app.buttons["guide.option.tailscale"].tapWhenReady()
        app.buttons["guide.next"].tapWhenReady()
        XCTAssertTrue(app.textFields["guide.field.port"].waitUntilExists(timeout: 5), "沒有到填主機那一頁")
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
        XCTAssertTrue(app.buttons["guide.option.password"].waitUntilExists(timeout: 5), "沒有到選登入方式那一頁")
    }
}

