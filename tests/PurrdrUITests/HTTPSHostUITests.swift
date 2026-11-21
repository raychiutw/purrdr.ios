import XCTest

/// 新增 HTTPS 主機(ADR-0010):走新增主機引導(#341、#344)。UI 測試的配對不連網路
/// (配對碼 `K7QM-2XPA` 成功、`R3AD-0NLY` 唯讀、`OLD0-CODE` 過期),連線是 Demo 主機。
final class HTTPSHostUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 配對、測試、儲存後列表顯示這台主機的 Agent,選單沒有登入 Shell 的限制(Demo 仍能開)。
    @MainActor
    func testAddHTTPSHostWithPairingCode() {
        let app = XCUIApplication.launchUITesting()
        pairManually(app, code: "K7QM-2XPA")

        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有通過連線測試")
        save.tap()
        app.buttons["guide.done"].tapWhenReady()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "agent.row.", "agent.row.demo/"))
            .firstMatch
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "列表沒有 HTTPS 主機的 Agent")
        app.buttons["toolbar.more"].tap()
        XCTAssertTrue(app.buttons["menu.hosts"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["menu.loginShell"].exists, "選取中主機是 HTTPS 時，Demo 仍能開登入 Shell")
    }

    /// 唯讀配對(配對碼 `R3AD-0NLY`,#60):聊天沒有輸入框，「需要你」卡片沒有選項，兩處都說明是唯讀。
    @MainActor
    func testReadOnlyDeviceHasNoComposerOrAnswers() {
        let app = XCUIApplication.launchUITesting()
        pairManually(app, code: "R3AD-0NLY")
        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有通過連線測試")
        save.tap()
        app.buttons["guide.done"].tapWhenReady()

        // Demo 的 w2:p1 卡在 Bash 權限(AnswerPromptUITests)。
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH %@ AND NOT (identifier BEGINSWITH %@)", "/w2:p1", "agent.row.demo/"))
            .firstMatch
        XCTAssertTrue(app.reveal(row), "列表沒有 HTTPS 主機的 Agent")
        row.tap()

        let card = app.descendants(matching: .any)["prompt.card"].firstMatch
        XCTAssertTrue(card.waitUntilExists(timeout: 10), "沒有提示卡")
        XCTAssertFalse(app.descendants(matching: .any)["prompt.readOnly"].firstMatch.exists, "提示卡不該再重複說明唯讀(只在橫幅，#349)")
        XCTAssertFalse(app.descendants(matching: .any)["prompt.option.1"].firstMatch.exists, "唯讀裝置不應該有回答選項")
        // 唯讀只在頂部浮動橫幅說明一次(#348):輸入列不再重複，橫幅浮在內容上(不貼齊螢幕邊緣)。
        let banners = app.descendants(matching: .any).matching(identifier: "conversation.banner")
        XCTAssertTrue(banners.firstMatch.waitUntilExists(timeout: 5), "沒有唯讀橫幅")
        XCTAssertEqual(banners.count, 1, "唯讀橫幅應只出現一次")
        XCTAssertFalse(app.descendants(matching: .any)["composer.readOnly"].firstMatch.exists, "輸入列不該再重複說明唯讀")
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(banners.firstMatch.frame.minX, 8, "橫幅應浮在內容上，不貼齊左緣")
        XCTAssertLessThanOrEqual(banners.firstMatch.frame.maxX, screen.maxX - 8, "橫幅應浮在內容上，不貼齊右緣")
        XCTAssertFalse(app.descendants(matching: .any)["composer.text"].firstMatch.exists, "唯讀裝置不應該有輸入框")
        XCTAssertFalse(app.descendants(matching: .any)["composer.send"].firstMatch.exists, "唯讀裝置不應該有送出鈕")
    }

    /// 主機服務比最新版舊(`-demoOutdatedHostService`,#198;UI 測試的最新版固定，不連 GitHub,#362):主機清單標示可更新，點進去有兩種作業系統的更新指令;
    /// 選「這個版本不再提醒」後標示消失。
    @MainActor
    func testOutdatedHostServiceOffersUpdate() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoOutdatedHostService"])
        pairManually(app, code: "K7QM-2XPA")
        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有通過連線測試")
        save.tap()
        app.buttons["guide.done"].tapWhenReady()

        app.buttons["toolbar.more"].tap()
        app.buttons["menu.hosts"].tap()
        let update = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "hosts.update.")).firstMatch
        XCTAssertTrue(update.waitUntilExists(timeout: 10), "主機清單沒有更新提示")
        XCTAssertTrue(app.descendants(matching: .any)["hosts.row.hostServiceUpdate"].firstMatch.exists, "主機列沒有標示可更新")
        update.tap()

        let posix = app.staticTexts["hostServiceUpdate.command.posix"]
        XCTAssertTrue(posix.waitUntilExists(timeout: 5), "沒有 macOS／Linux 的更新指令")
        XCTAssertTrue(posix.label.contains("install.sh | sh"), posix.label)
        XCTAssertTrue(app.staticTexts["hostServiceUpdate.command.windows"].label.contains("install.ps1 | iex"))
        let dismiss = app.buttons["hostServiceUpdate.dismiss"]
        XCTAssertTrue(dismiss.waitUntilExists(timeout: 5))
        dismiss.tap()

        XCTAssertTrue(app.buttons["hosts.add"].waitUntilExists(timeout: 5), "沒有回到主機清單")
        XCTAssertFalse(update.exists, "關閉後仍有更新提示")
        XCTAssertFalse(app.descendants(matching: .any)["hosts.row.hostServiceUpdate"].firstMatch.exists, "關閉後主機列仍標示可更新")
    }

    /// 配對碼過期：說明原因，不能儲存。
    @MainActor
    func testExpiredPairingCodeIsExplained() {
        let app = XCUIApplication.launchUITesting()
        pairManually(app, code: "OLD0-CODE")

        let expired = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "pairing code expired")).firstMatch
        XCTAssertTrue(expired.waitUntilExists(timeout: 15), "沒有說明配對碼過期")
        XCTAssertFalse(app.buttons["guide.save"].exists, "配對失敗不能儲存")
    }

    /// 配對碼是大寫字母(#236、HIG TF-1):欄位用全大寫鍵盤，小寫鍵入的字變成大寫。
    @MainActor
    func testPairingCodeUsesUppercaseKeyboard() {
        let app = XCUIApplication.launchUITesting()
        openPairStep(app)
        app.buttons["Enter It Manually"].firstMatch.tapWhenReady()

        let code = app.textFields["guide.field.pairingCode"]
        XCTAssertTrue(code.waitUntilExists(timeout: 5))
        code.tap()
        code.typeEnglish("k7qm-2xpa")
        XCTAssertEqual(code.value as? String, "K7QM-2XPA")
    }

    /// 主機同步帶來、這支裝置還沒配對的 HTTPS 主機：主機清單標示要配對，點它進引導的配對那一步;配對儲存後標示消失。
    @MainActor
    func testUnpairedHTTPSHostOpensPairing() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedUnpairedHTTPSHost"])
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitUntilExists(timeout: 10))
        more.tap()
        app.buttons["menu.hosts"].tap()

        let row = app.buttons["hosts.row.5EED0000-0000-4000-8000-000000000003"]
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        XCTAssertTrue(row.label.contains("Not Paired on This Device"), "沒有標示要配對：\(row.label)")
        row.tap()

        let address = app.textFields["guide.field.pairAddress"]
        XCTAssertTrue(address.waitUntilExists(timeout: 5), "沒有開配對")
        XCTAssertEqual(address.value as? String, "studio.tail1234.ts.net")
        let next = app.buttons["guide.next"]
        XCTAssertFalse(next.isEnabled, "沒有配對碼不能往下")
        let code = app.textFields["guide.field.pairingCode"]
        code.tap()
        code.typeEnglish("K7QM-2XPA")
        next.tap()
        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有連上")
        save.tap()
        app.buttons["guide.done"].tapWhenReady()

        more.tap()
        app.buttons["menu.hosts"].tap()
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        XCTAssertFalse(row.label.contains("Not Paired on This Device"), "配對後不應該再標示")
    }

    // MARK: - 輔助

    /// 從主機清單的「＋」開引導，選 HTTPS、Linux，到配對那一頁。
    @MainActor
    private func openPairStep(_ app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitUntilExists(timeout: 10))
        more.tap()
        app.buttons["menu.hosts"].tap()
        let add = app.buttons["hosts.add"]
        XCTAssertTrue(add.waitUntilExists(timeout: 5))
        add.tap()
        app.buttons["guide.option.https"].tapWhenReady()
        app.buttons["guide.next"].tapWhenReady()
        app.buttons["guide.option.linux"].tapWhenReady()
        app.buttons["guide.next"].tapWhenReady()
        XCTAssertTrue(app.buttons["Enter It Manually"].firstMatch.waitUntilExists(timeout: 5), "沒有到配對那一頁")
    }

    /// 手動輸入位址與配對碼，按下一步開始測試連線。
    @MainActor
    private func pairManually(_ app: XCUIApplication, code: String) {
        openPairStep(app)
        app.buttons["Enter It Manually"].firstMatch.tapWhenReady()
        let address = app.textFields["guide.field.pairAddress"]
        address.tapWhenReady()
        address.typeEnglish("studio.tail1234.ts.net")
        let field = app.textFields["guide.field.pairingCode"]
        field.tap()
        field.typeEnglish(code)
        app.buttons["guide.next"].tap()
    }
}

