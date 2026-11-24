import XCTest

/// 新增 HTTPS 主機(ADR-0010):走新增主機引導(#341、#344)。UI 測試的配對不連網路
/// (配對碼 `K7QM-2XPA` 成功、`R3AD-0NLY` 唯讀、`OLD0-CODE` 過期),連線是 Demo 主機。
final class HTTPSHostUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// 一次啟動串起 HTTPS 主機的流程(#374 瘦身;原本各自啟動;未配對主機的捷徑在 `AddHostGuideUITests`)。
    /// `-demoOutdatedHostService` 讓 HTTPS 主機都回報舊版主機服務。順序:先在引導裡驗證配對碼(不存主機),
    /// 再依序配對唯讀與可寫的主機。
    @MainActor
    func testHTTPSHostPairingFlows() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoOutdatedHostService"])

        // 配對碼是大寫字母(#236、HIG TF-1):欄位用全大寫鍵盤，小寫鍵入的字變成大寫;過期的配對碼說明原因、不能儲存。
        step("配對碼自動大寫，過期的配對碼說明原因") {
            openPairStep(app)
            app.buttons["Enter It Manually"].firstMatch.tapWhenReady()
            let address = app.textFields["guide.field.pairAddress"]
            address.tapWhenReady()
            address.typeEnglish("studio.tail1234.ts.net")
            let code = app.textFields["guide.field.pairingCode"]
            XCTAssertTrue(code.waitUntilExists(timeout: 5))
            code.tap()
            code.typeEnglish("old0-code")
            XCTAssertEqual(code.value as? String, "OLD0-CODE")
            app.buttons["guide.next"].tap()

            let expired = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "pairing code expired")).firstMatch
            XCTAssertTrue(expired.waitUntilExists(timeout: 15), "沒有說明配對碼過期")
            XCTAssertFalse(app.buttons["guide.save"].exists, "配對失敗不能儲存")
            app.buttons["guide.cancel"].firstMatch.tap()
            XCTAssertTrue(app.buttons["hosts.add"].waitUntilExists(timeout: 5), "取消後沒有回到主機清單")
        }

        // 唯讀配對(配對碼 `R3AD-0NLY`,#60):聊天沒有輸入框，「需要你」卡片沒有選項，兩處都說明是唯讀。
        step("唯讀裝置沒有輸入列與回答選項") {
            pairManually(app, code: "R3AD-0NLY")
            let save = app.buttons["guide.save"]
            XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有通過連線測試")
            save.tap()
            app.buttons["guide.done"].tapWhenReady()
            app.openTab(.chats)

            // Demo 的 w2:p1 卡在 Bash 權限(AnswerPromptUITests)。此時只有這一台 HTTPS 主機。
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier ENDSWITH %@ AND NOT (identifier BEGINSWITH %@)", "/w2:t1", "spaces.tab.demo/"))
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
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // 配對、測試、儲存後列表顯示這台主機的 Agent,HTTPS 主機沒有登入 Shell;
        // 主機服務比最新版舊(#198;UI 測試的最新版固定，不連 GitHub,#362):主機 tab 標示可更新，點進去有兩種作業系統的更新指令;
        // 選「這個版本不再提醒」後這台的標示消失。
        step("配對可寫主機後列表有 Agent，並提示更新主機服務") {
            pairManually(app, code: "K7QM-2XPA")
            let save = app.buttons["guide.save"]
            XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有通過連線測試")
            save.tap()
            app.buttons["guide.done"].tapWhenReady()
            app.openTab(.chats)

            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "spaces.tab.", "spaces.tab.demo/"))
                .firstMatch
            XCTAssertTrue(row.waitUntilExists(timeout: 10), "列表沒有 HTTPS 主機的 Agent")
            app.openHostsTab()
            XCTAssertTrue(app.element("hosts.status").waitUntilExists(timeout: 5), "主機 tab 沒有連線狀態")
            XCTAssertFalse(app.buttons["hosts.tool.loginShell"].exists, "HTTPS 主機沒有登入 Shell")

            let updates = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "hosts.update."))
            _ = updates.firstMatch.waitUntilExists(timeout: 10)
            XCTAssertTrue(app.scrollIntoView(updates.firstMatch, timeout: 5), "主機 tab 沒有更新提示")
            let before = updates.count
            updates.firstMatch.tap()

            let posix = app.staticTexts["hostServiceUpdate.command.posix"]
            XCTAssertTrue(posix.waitUntilExists(timeout: 5), "沒有 macOS／Linux 的更新指令")
            XCTAssertTrue(posix.label.contains("install.sh | sh"), posix.label)
            XCTAssertTrue(app.staticTexts["hostServiceUpdate.command.windows"].label.contains("install.ps1 | iex"))
            let dismiss = app.buttons["hostServiceUpdate.dismiss"]
            XCTAssertTrue(dismiss.waitUntilExists(timeout: 5))
            dismiss.tap()

            app.scrollToTopBar(containing: "hosts.add")
            XCTAssertTrue(app.buttons["hosts.add"].waitUntilExists(timeout: 5), "沒有回到主機 tab")
            XCTAssertTrue(UITestWait.until(timeout: 5) { updates.count == before - 1 }, "關閉後那台仍有更新提示(\(before) → \(updates.count))")
        }
    }

    // MARK: - 輔助

    /// 從主機清單的「＋」(不在清單時先從「⋯」選單開)開引導，選 HTTPS、Linux，到配對那一頁。
    @MainActor
    private func openPairStep(_ app: XCUIApplication) {
        // 已在主機清單(例如取消上一段引導後)就直接用「＋」。
        if !app.buttons["hosts.add"].waitUntilExists(timeout: 2) {
            app.openHostsTab()
        }
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

