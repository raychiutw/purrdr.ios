import XCTest

/// 新增主機引導(#341):從主機清單的「＋」走完 Tailscale SSH 並存成主機;一頁一件事、可返回與取消、每個指令可拷貝與分享。
final class AddHostGuideUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTailscaleSSHPathSavesHost() {
        let app = XCUIApplication.launchUITesting(flags: [])
        openGuide(app)

        XCTAssertTrue(app.staticTexts["guide.title"].exists)
        XCTAssertTrue(app.buttons["guide.option.ssh"].exists)
        XCTAssertTrue(app.buttons["guide.option.https"].exists)
        XCTAssertFalse(app.textFields["guide.field.address"].exists, "第一頁不該出現欄位")
        app.buttons["guide.option.ssh"].tap()

        app.buttons["guide.option.macOS"].tapWhenReady()
        app.buttons["guide.option.tailscale"].tapWhenReady()

        // 開啟 SSH:指令可拷貝與分享到電腦。
        XCTAssertTrue(app.staticTexts["tailscale set --ssh"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["guide.copy"].exists)
        XCTAssertTrue(app.buttons["guide.share"].exists)
        app.buttons["guide.next"].tap()

        // 主機名稱、Port、帳號:Port 預設 22,每欄有「怎麼查」。
        let address = app.textFields["guide.field.address"]
        XCTAssertTrue(address.waitUntilExists(timeout: 5))
        XCTAssertEqual(app.textFields["guide.field.port"].value as? String, "22")
        XCTAssertFalse(app.buttons["guide.next"].isEnabled, "還沒填主機與帳號就能往下")
        address.tap()
        address.typeEnglish("studio-mac")
        let username = app.textFields["guide.field.username"]
        username.tap()
        username.typeEnglish("ray")
        XCTAssertTrue(app.buttons["guide.next"].isEnabled)
        app.buttons["guide.next"].tap()

        // 測試連線(UI 測試的通道是 Demo 主機)通過後加入。
        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有通過連線測試\n\(app.debugDescription)")
        save.tap()
        XCTAssertTrue(app.buttons["guide.done"].waitUntilExists(timeout: 5))
        app.buttons["guide.done"].tap()

        XCTAssertTrue(app.buttons["toolbar.more"].waitUntilExists(timeout: 10), "沒有回到 Agent 列表")
        app.buttons["toolbar.more"].tap()
        app.buttons["menu.hosts"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "studio-mac")).firstMatch.waitUntilExists(timeout: 5),
            "主機清單沒有新增的主機")
    }

    /// 原生 SSH(#342):開啟 SSH → 在哪裡連 → 主機與帳號 → 密碼 → 測試連線並加入;密碼路徑不出現「key」。
    @MainActor
    func testNativeSSHPasswordPath() {
        let app = XCUIApplication.launchUITesting(flags: [])
        openGuide(app)
        app.buttons["guide.option.ssh"].tap()
        app.buttons["guide.option.macOS"].tapWhenReady()
        app.buttons["guide.option.native"].tapWhenReady()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Remote Login")).firstMatch.waitUntilExists(timeout: 5))
        app.buttons["guide.next"].tap()

        app.buttons["guide.option.home"].tapWhenReady()
        let address = app.textFields["guide.field.address"]
        XCTAssertTrue(address.waitUntilExists(timeout: 5))
        app.buttons["How do I find this?"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["ipconfig getifaddr en0"].waitUntilExists(timeout: 5))
        address.tap()
        address.typeEnglish("192.168.1.20")
        let username = app.textFields["guide.field.username"]
        username.tap()
        username.typeEnglish("ray")
        app.buttons["guide.next"].tap()

        app.buttons["guide.option.password"].tapWhenReady()
        let password = app.secureTextFields["guide.field.password"]
        XCTAssertTrue(password.waitUntilExists(timeout: 5))
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "key")).firstMatch.exists, "密碼路徑出現了「key」")
        XCTAssertFalse(app.buttons["guide.next"].isEnabled)
        password.tap()
        password.typeEnglish("hunter2")
        app.buttons["guide.next"].tap()

        // 第一次連線:只問信任／取消(Demo 主機若直接通過就沒有這一步)。
        let trust = app.buttons["guide.trust"]
        let save = app.buttons["guide.save"]
        XCTAssertTrue(UITestWait.until(timeout: 15) { trust.exists || save.exists }, "沒有進到信任或加入\n\(app.debugDescription)")
        if trust.exists { trust.tap() }
        XCTAssertTrue(save.waitUntilExists(timeout: 15))
        save.tap()
        XCTAssertTrue(app.buttons["guide.done"].waitUntilExists(timeout: 5))
    }

    /// HTTPS:準備 Tailscale、裝主機服務、掃 QR code 配對(`-uiTestingPairingScan`)、測試、存檔。
    @MainActor
    func testHTTPSPathScansAndSavesHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPairingScan"])
        openGuide(app)
        app.buttons["guide.option.https"].tap()

        // 準備 Tailscale:App Store 與下載頁連結都能分享到電腦。
        XCTAssertTrue(app.descendants(matching: .any)["guide.link"].firstMatch.waitUntilExists(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["guide.shareLink"].firstMatch.exists)
        app.buttons["guide.next"].tapWhenReady()

        app.buttons["guide.option.macOS"].tapWhenReady()
        XCTAssertTrue(
            app.staticTexts["curl -fsSL https://github.com/raychiutw/purrdr.host/releases/latest/download/install.sh | sh"]
                .waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["guide.copy"].exists)
        XCTAssertTrue(app.buttons["guide.share"].exists)
        app.buttons["guide.next"].tap()

        XCTAssertTrue(app.staticTexts["purrdr pair"].waitUntilExists(timeout: 5))
        app.buttons["guide.scan"].tapWhenReady()

        // 掃到後自動測試連線(UI 測試的連線是 Demo 主機)。
        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有通過連線測試\n\(app.debugDescription)")
        save.tap()
        app.buttons["guide.done"].tapWhenReady()

        XCTAssertTrue(app.buttons["toolbar.more"].waitUntilExists(timeout: 10), "沒有回到 Agent 列表")
        app.buttons["toolbar.more"].tap()
        app.buttons["menu.hosts"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "studio")).firstMatch.waitUntilExists(timeout: 5),
            "主機清單沒有新增的主機")
    }

    /// 捷徑:同步來、這支裝置還沒配對的主機直接到配對。
    @MainActor
    func testUnpairedHostGoesStraightToPairing() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedUnpairedHTTPSHost"])
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitUntilExists(timeout: 10))
        more.tap()
        app.buttons["menu.hosts"].tap()
        let row = app.buttons["hosts.row.5EED0000-0000-4000-8000-000000000003"]
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        row.tap()
        XCTAssertTrue(app.textFields["guide.field.pairAddress"].waitUntilExists(timeout: 5), "沒有直接到配對")
        XCTAssertEqual(app.textFields["guide.field.pairAddress"].value as? String, "studio.tail1234.ts.net")
        let code = app.textFields["guide.field.pairingCode"]
        code.tap()
        code.typeEnglish("K7QM-2XPA")
        app.buttons["guide.next"].tap()
        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有通過連線測試")
        save.tap()
        app.buttons["guide.done"].tapWhenReady()
        more.tap()
        app.buttons["menu.hosts"].tap()
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        XCTAssertFalse(row.label.contains("Not Paired on This Device"), "配對後不應該再標示")
    }

    /// 無障礙稽核(預設與 AX5):選項頁、開啟 SSH 頁、填主機頁。
    @MainActor
    func testAccessibilityAudit() throws {
        for size in [nil, "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication.launchUITesting(flags: [], contentSize: size)
            openGuide(app)
            try audit(app, "新增主機引導(選連線方式)", contentSize: size)
            app.buttons["guide.option.ssh"].tap()
            app.buttons["guide.option.macOS"].tapWhenReady()
            app.buttons["guide.option.tailscale"].tapWhenReady()
            XCTAssertTrue(app.buttons["guide.next"].waitUntilExists(timeout: 5))
            try audit(app, "新增主機引導(開啟 SSH)", contentSize: size)
            app.buttons["guide.next"].tap()
            XCTAssertTrue(app.textFields["guide.field.address"].waitUntilExists(timeout: 5))
            try audit(app, "新增主機引導(填主機)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    private func openGuide(_ app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitUntilExists(timeout: 10))
        more.tap()
        app.buttons["menu.hosts"].tap()
        let add = app.buttons["hosts.add"]
        XCTAssertTrue(add.waitUntilExists(timeout: 5))
        add.tap()
        XCTAssertTrue(app.buttons["guide.option.ssh"].waitUntilExists(timeout: 5), "沒有開出新增主機引導")
    }
}

