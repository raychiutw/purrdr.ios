import XCTest

/// 新增 HTTPS 主機(ADR-0010)。UI 測試的配對不連網路(配對碼 `K7QM-2XPA` 成功、`OLD0-CODE` 過期),連線是 Demo 主機。
final class HTTPSHostUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 選 HTTPS 只填位址與配對碼，說明不支援登入 Shell;配對、測試、儲存後列表顯示這台主機的 Agent,選單沒有登入 Shell。
    @MainActor
    func testAddHTTPSHostWithPairingCode() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        chooseHTTPS(app)

        XCTAssertFalse(app.textFields["hostEditor.username"].exists, "HTTPS 不需要使用者名稱")
        let explanation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Login Shell")).firstMatch
        XCTAssertTrue(explanation.exists || scrollTo(explanation, in: app), "沒有說明 HTTPS 不支援登入 Shell")
        fill(app, code: "K7QM-2XPA")

        let test = app.buttons["hostEditor.test"]
        XCTAssertTrue(test.exists || scrollTo(test, in: app))
        test.tap()
        // 結果列(Label)裡有兩行文字，各自帶 identifier:以文字找第一行。
        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Connected")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 10) || scrollTo(connected, in: app), "沒有連上")
        let save = app.buttons["hostEditor.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "agent.row.", "agent.row.demo/"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "列表沒有 HTTPS 主機的 Agent")
        app.buttons["toolbar.more"].tap()
        XCTAssertTrue(app.buttons["menu.hosts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["menu.loginShell"].exists, "選取中主機是 HTTPS 時，Demo 仍能開登入 Shell")
    }

    /// 唯讀配對(配對碼 `R3AD-0NLY`,#60):聊天沒有輸入框，「需要你」卡片沒有選項，兩處都說明是唯讀。
    @MainActor
    func testReadOnlyDeviceHasNoComposerOrAnswers() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        chooseHTTPS(app)
        fill(app, code: "R3AD-0NLY")
        let test = app.buttons["hostEditor.test"]
        XCTAssertTrue(test.exists || scrollTo(test, in: app))
        test.tap()
        let readOnly = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Read-only")).firstMatch
        XCTAssertTrue(readOnly.waitForExistence(timeout: 10) || scrollTo(readOnly, in: app), "連線結果沒有標示唯讀")
        app.buttons["hostEditor.save"].tap()

        // Demo 的 w2:p1 卡在 Bash 權限(AnswerPromptUITests)。
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH %@ AND NOT (identifier BEGINSWITH %@)", "/w2:p1", "agent.row.demo/"))
            .firstMatch
        XCTAssertTrue(app.reveal(row), "列表沒有 HTTPS 主機的 Agent")
        row.tap()

        let card = app.descendants(matching: .any)["prompt.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "沒有提示卡")
        XCTAssertFalse(app.descendants(matching: .any)["prompt.readOnly"].firstMatch.exists, "提示卡不該再重複說明唯讀(只在橫幅，#349)")
        XCTAssertFalse(app.descendants(matching: .any)["prompt.option.1"].firstMatch.exists, "唯讀裝置不應該有回答選項")
        // 唯讀只在頂部浮動橫幅說明一次(#348):輸入列不再重複，橫幅浮在內容上(不貼齊螢幕邊緣)。
        let banners = app.descendants(matching: .any).matching(identifier: "conversation.banner")
        XCTAssertTrue(banners.firstMatch.waitForExistence(timeout: 5), "沒有唯讀橫幅")
        XCTAssertEqual(banners.count, 1, "唯讀橫幅應只出現一次")
        XCTAssertFalse(app.descendants(matching: .any)["composer.readOnly"].firstMatch.exists, "輸入列不該再重複說明唯讀")
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(banners.firstMatch.frame.minX, 8, "橫幅應浮在內容上，不貼齊左緣")
        XCTAssertLessThanOrEqual(banners.firstMatch.frame.maxX, screen.maxX - 8, "橫幅應浮在內容上，不貼齊右緣")
        XCTAssertFalse(app.descendants(matching: .any)["composer.text"].firstMatch.exists, "唯讀裝置不應該有輸入框")
        XCTAssertFalse(app.descendants(matching: .any)["composer.send"].firstMatch.exists, "唯讀裝置不應該有送出鈕")
    }

    /// 主機服務比 app 已知的舊(`-demoOutdatedHostService`,#198):主機清單標示可更新，點進去有兩種作業系統的更新指令;
    /// 選「這個版本不再提醒」後標示消失。
    @MainActor
    func testOutdatedHostServiceOffersUpdate() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoOutdatedHostService"])
        openAddHost(app)
        chooseHTTPS(app)
        fill(app, code: "K7QM-2XPA")
        let test = app.buttons["hostEditor.test"]
        XCTAssertTrue(test.exists || scrollTo(test, in: app))
        test.tap()
        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Connected")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 10) || scrollTo(connected, in: app), "沒有連上")
        app.buttons["hostEditor.save"].tap()

        app.buttons["toolbar.more"].tap()
        app.buttons["menu.hosts"].tap()
        let update = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "hosts.update.")).firstMatch
        XCTAssertTrue(update.waitForExistence(timeout: 10), "主機清單沒有更新提示")
        XCTAssertTrue(app.descendants(matching: .any)["hosts.row.hostServiceUpdate"].firstMatch.exists, "主機列沒有標示可更新")
        update.tap()

        let posix = app.staticTexts["hostServiceUpdate.command.posix"]
        XCTAssertTrue(posix.waitForExistence(timeout: 5), "沒有 macOS／Linux 的更新指令")
        XCTAssertTrue(posix.label.contains("install.sh | sh"), posix.label)
        XCTAssertTrue(app.staticTexts["hostServiceUpdate.command.windows"].label.contains("install.ps1 | iex"))
        let dismiss = app.buttons["hostServiceUpdate.dismiss"]
        XCTAssertTrue(dismiss.exists || scrollTo(dismiss, in: app))
        dismiss.tap()

        XCTAssertTrue(app.buttons["hosts.add"].waitForExistence(timeout: 5), "沒有回到主機清單")
        XCTAssertFalse(update.exists, "關閉後仍有更新提示")
        XCTAssertFalse(app.descendants(matching: .any)["hosts.row.hostServiceUpdate"].firstMatch.exists, "關閉後主機列仍標示可更新")
    }

    /// 配對碼過期：說明原因，不能儲存。
    @MainActor
    func testExpiredPairingCodeIsExplained() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        chooseHTTPS(app)
        fill(app, code: "OLD0-CODE")

        let test = app.buttons["hostEditor.test"]
        XCTAssertTrue(test.exists || scrollTo(test, in: app))
        test.tap()

        let expired = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "pairing code expired")).firstMatch
        XCTAssertTrue(expired.waitForExistence(timeout: 10) || scrollTo(expired, in: app), "沒有說明配對碼過期")
        XCTAssertFalse(app.buttons["hostEditor.save"].isEnabled)
    }

    /// 配對碼是大寫字母(#236、HIG TF-1):欄位用全大寫鍵盤，小寫鍵入的字變成大寫。
    @MainActor
    func testPairingCodeUsesUppercaseKeyboard() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        chooseHTTPS(app)
        app.swipeDown()

        let code = app.textFields["hostEditor.pairingCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 5) || scrollTo(code, in: app))
        code.tap()
        code.typeEnglish("k7qm-2xpa")
        XCTAssertEqual(code.value as? String, "K7QM-2XPA")
    }

    /// 系統相機掃主機配對指令的 QR code(`purrdr://pair?…`):開啟新增主機，帶入 HTTPS、位址與配對碼。
    @MainActor
    func testPairingLinkFillsAddHost() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.buttons["toolbar.more"].waitForExistence(timeout: 10))

        app.open(URL(string: "purrdr://pair?address=https%3A%2F%2Fstudio.tail1234.ts.net%3A8443&code=K7QM-2XPA")!)

        let address = app.textFields["hostEditor.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10) || scrollTo(address, in: app))
        XCTAssertEqual(address.value as? String, "studio.tail1234.ts.net")
        XCTAssertEqual(app.textFields["hostEditor.port"].value as? String, "8443")
        XCTAssertEqual(app.textFields["hostEditor.pairingCode"].value as? String, "K7QM-2XPA")
    }

    /// 主機同步帶來、這支裝置還沒配對的 HTTPS 主機：主機清單標示要配對，點它開配對;配對儲存後標示消失。
    @MainActor
    func testUnpairedHTTPSHostOpensPairing() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedUnpairedHTTPSHost"])
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["menu.hosts"].tap()

        let row = app.buttons["hosts.row.5EED0000-0000-4000-8000-000000000003"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Not Paired on This Device"), "沒有標示要配對：\(row.label)")
        row.tap()

        // 編輯器先是名稱、圖示格(#239)與連線方式卡片(#250),配對欄位在畫面外;Form 不建立畫面外的列，先捲過去。
        XCTAssertTrue(app.textFields["hostEditor.name"].waitForExistence(timeout: 5), "沒有開配對")
        let address = app.textFields["hostEditor.address"]
        XCTAssertTrue(address.exists || scrollTo(address, in: app), "沒有位址欄位")
        XCTAssertEqual(address.value as? String, "studio.tail1234.ts.net")
        let code = app.textFields["hostEditor.pairingCode"]
        XCTAssertTrue(code.exists || scrollTo(code, in: app), "沒有配對碼欄位")
        let test = app.buttons["hostEditor.test"]
        XCTAssertTrue(test.exists || scrollTo(test, in: app))
        XCTAssertFalse(test.isEnabled, "沒有配對碼不能測試")
        code.tap()
        code.typeEnglish("K7QM-2XPA")
        test.tap()
        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Connected")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 10) || scrollTo(connected, in: app), "沒有連上")
        app.buttons["hostEditor.save"].tap()

        more.tap()
        app.buttons["menu.hosts"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.label.contains("Not Paired on This Device"), "配對後不應該再標示")
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
    }

    @MainActor
    private func chooseHTTPS(_ app: XCUIApplication) {
        let https = app.buttons["hostEditor.method.https"]
        XCTAssertTrue(https.waitForExistence(timeout: 5) || scrollTo(https, in: app), "沒有 HTTPS 連線方式")
        https.tap()
    }

    @MainActor
    private func fill(_ app: XCUIApplication, code: String) {
        app.swipeDown()
        for (identifier, text) in [("name", "Studio"), ("address", "studio.tail1234.ts.net"), ("pairingCode", code)] {
            let field = app.textFields["hostEditor.\(identifier)"]
            XCTAssertTrue(scrollTo(field, in: app), "沒有 \(identifier) 欄位")
            field.tap()
            field.typeEnglish(text)
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
