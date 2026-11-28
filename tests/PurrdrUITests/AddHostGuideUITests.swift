import XCTest

/// 新增主機引導(#341):從主機清單的「＋」走完 Tailscale SSH 並存成主機;一頁一件事、可返回與取消、每個指令可拷貝與分享。
final class AddHostGuideUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 一次啟動串起新增主機引導的主流程(#374 瘦身;原本各自啟動):同步來未配對的主機直接到配對、Tailscale SSH、原生 SSH 密碼、
    /// HTTPS 掃 QR code。`-uiTestingPairingScan` 讓掃描畫面一開就掃到配對 QR code,`-seedUnpairedHTTPSHost` 預先放一台
    /// 未配對的 HTTPS 主機(兩者互不影響)。每段結束都回到沒有 sheet 的 Agent 列表(HTTPS 段最後停在主機 tab)。
    @MainActor
    func testAddHostFlows() {
        let app = XCUIApplication.launchUITesting(flags: [.uiTestingPairingScan, .seedUnpairedHTTPSHost])

        // 捷徑:同步來、這支裝置還沒配對的主機標示要配對，點它直接到配對頁;配對儲存後標示消失。
        step("未配對的 HTTPS 主機直接到配對") {
            app.openHostsTab()
            app.selectHostOnHostsTab("Studio HTTPS")
            let status = app.staticTexts["Not Paired on This Device"].firstMatch
            XCTAssertTrue(status.waitUntilExists(timeout: 5), "沒有標示要配對")
            app.buttons["hosts.status.pair"].tap()
            let address = app.textFields["guide.field.pairAddress"]
            XCTAssertTrue(address.waitUntilExists(timeout: 5), "沒有直接到配對")
            XCTAssertEqual(address.value as? String, "studio.tail1234.ts.net")
            XCTAssertFalse(app.buttons["guide.next"].isEnabled, "沒有配對碼不能往下")
            // 掃 QR code(`-uiTestingPairingScan` 一開就掃到配對碼 K7QM-2XPA):帶入配對碼並直接測試連線。
            app.buttons["guide.scan"].tapWhenReady()
            let save = app.buttons["guide.save"]
            XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有通過連線測試")
            save.tap()
            app.buttons["guide.done"].tapWhenReady()
            app.openHostsTab()
            XCTAssertTrue(app.element("hosts.status").waitUntilExists(timeout: 5))
            XCTAssertTrue(app.staticTexts["Not Paired on This Device"].waitUntilGone(timeout: 5), "配對後不應該再標示")
            app.selectHostOnHostsTab("Demo")
        }

        step("Tailscale SSH 路徑存成主機") {
            openGuide(app)

            XCTAssertTrue(app.staticTexts["guide.title"].exists)
            XCTAssertTrue(app.buttons["guide.option.ssh"].exists)
            XCTAssertTrue(app.buttons["guide.option.https"].exists)
            XCTAssertFalse(app.textFields["guide.field.address"].exists, "第一頁不該出現欄位")
            app.buttons["guide.option.ssh"].tap()

            // 每一步是 push 的一頁:左上是系統返回鈕(回上一步),沒有另外的 Cancel(#622)。
            XCTAssertTrue(app.buttons["guide.option.macOS"].waitUntilExists(timeout: 5))
            XCTAssertFalse(app.buttons["Cancel"].exists, "引導不該有 Cancel")
            XCTAssertFalse(app.buttons["guide.cancel"].exists, "引導不該有 Cancel")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["guide.option.ssh"].waitUntilExists(timeout: 5), "左上 < 沒有回上一步")
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

            app.openHostsTab()
            XCTAssertTrue(app.overviewRow("hosts.edit").exists, "主機 tab 沒有新增的主機")
            app.selectHostOnHostsTab("Demo")  // 選回 Demo,下一段從乾淨的狀態開始
        }

        // 原生 SSH(#342):開啟 SSH → 在哪裡連 → 主機與帳號 → 密碼 → 測試連線並加入;密碼路徑不出現「key」。
        step("原生 SSH 密碼路徑") {
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
            app.buttons["guide.done"].tapWhenReady()
        }

        // HTTPS:準備 Tailscale、裝主機服務、掃 QR code 配對、測試、存檔。
        step("HTTPS 路徑掃 QR code 存成主機") {
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

            app.openHostsTab()
            XCTAssertTrue(app.buttons["hosts.add"].waitUntilExists(timeout: 5), "沒有回到主機 tab")
        }
    }

    /// #726:深色模式、XXXL 字級下,停用的主要按鈕(還沒填主機與帳號的「Next」)仍在畫面上有完整高度與文字(不是空的黑色長條);
    /// 連線中的面板沒有停用按鈕由單元測試 `DisabledProminentButtonTests` 守門(Demo 的連線太快,UI 測試停不在連線中)。
    /// 顏色對比無法用 frame 量測,實機視覺另看。
    @MainActor
    func testDisabledPrimaryStaysVisibleInDarkAtXXXL() {
        let app = XCUIApplication.launchUITesting(
            arguments: ["-AppleInterfaceStyle", "Dark"], contentSize: "UICTContentSizeCategoryXXXL")
        openGuide(app)
        app.buttons["guide.option.ssh"].tap()
        app.buttons["guide.option.macOS"].tapWhenReady()
        app.buttons["guide.option.tailscale"].tapWhenReady()
        app.buttons["guide.next"].tapWhenReady()
        XCTAssertTrue(app.textFields["guide.field.address"].waitUntilExists(timeout: 5))
        let next = app.buttons["guide.next"]
        XCTAssertTrue(next.exists)
        XCTAssertFalse(next.isEnabled, "還沒填主機與帳號,按鈕應停用")
        XCTAssertFalse(next.label.isEmpty, "停用的按鈕沒有文字")
        XCTAssertGreaterThanOrEqual(next.frame.height, 44)
        XCTAssertFalse(app.buttons["guide.connecting"].exists)
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
    private func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// #727:最後一頁的通知開關列照內容長高,預設、XXXL、AX5 字級下開關都完整落在卡片內、可點(系統開關,觸控目標由系統保證)。
    @MainActor
    func testNotificationRowFitsCardAtLargeText() {
        for size in [nil, "UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication.launchUITesting(flags: [.uiTestingPlusMember], contentSize: size)
            let label = size ?? "預設"
            openGuide(app)
            app.buttons["guide.option.ssh"].tapWhenReady()
            app.buttons["guide.option.macOS"].tapWhenReady()
            app.buttons["guide.option.tailscale"].tapWhenReady()
            app.buttons["guide.next"].tapWhenReady()
            let address = app.textFields["guide.field.address"]
            XCTAssertTrue(address.waitUntilExists(timeout: 5))
            address.tap()
            address.typeEnglish("studio-mac")
            let username = app.textFields["guide.field.username"]
            username.tap()
            username.typeEnglish("ray")
            app.buttons["guide.next"].tapWhenReady()
            let save = app.buttons["guide.save"]
            XCTAssertTrue(save.waitUntilExists(timeout: 15), "\(label):沒有通過連線測試")
            save.tap()
            let card = app.element("guide.notifications")
            XCTAssertTrue(card.waitUntilExists(timeout: 10), "\(label):沒有通知開關")
            let toggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'account.push.'")).firstMatch
            XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "\(label):沒有開關")
            let c = card.frame, t = toggle.frame
            print("MEASURE \(label) card=\(c) toggle=\(t)")
            XCTAssertGreaterThanOrEqual(t.minY, c.minY - 0.5, "\(label):開關上緣超出卡片 card=\(c) toggle=\(t)")
            XCTAssertLessThanOrEqual(t.maxY, c.maxY + 0.5, "\(label):開關下緣超出卡片(被截斷) card=\(c) toggle=\(t)")
            XCTAssertTrue(toggle.isHittable, "\(label):開關點不到")
            app.terminate()
        }
    }

    @MainActor
    private func openGuide(_ app: XCUIApplication) {
        app.openHostsTab()
        let add = app.buttons["hosts.add"]
        XCTAssertTrue(add.waitUntilExists(timeout: 5))
        add.tap()
        XCTAssertTrue(app.buttons["guide.option.ssh"].waitUntilExists(timeout: 5), "沒有開出新增主機引導")
    }
}

