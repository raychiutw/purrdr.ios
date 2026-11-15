import XCTest

/// 主機清單與新增主機(UI 測試只用 Demo 主機，不連網路)。
final class HostsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 沒有主機時選的是 Demo 主機;新增主機表單的欄位都有標籤，填完必填欄位才能測試，測試前不能儲存。
    @MainActor
    func testAddHostFormRequiresTestBeforeSaving() {
        let app = XCUIApplication.launchUITesting()

        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let hostsItem = app.buttons["menu.hosts"]
        XCTAssertTrue(hostsItem.waitForExistence(timeout: 5))
        hostsItem.tap()

        let demo = app.buttons["hosts.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        XCTAssertTrue(demo.isSelected, "沒有主機時應選取 Demo 主機")

        app.buttons["hosts.add"].tap()
        let test = app.buttons["hostEditor.test"]
        XCTAssertTrue(test.waitForExistence(timeout: 5))
        XCTAssertFalse(test.isEnabled, "必填欄位沒填就能測試")
        XCTAssertFalse(app.buttons["hostEditor.save"].isEnabled, "沒測試就能儲存")
        let method = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Tailscale SSH")).firstMatch
        XCTAssertTrue(method.exists, "沒有顯示連線方式")

        for (identifier, text) in [("name", "Studio"), ("address", "studio-mac"), ("username", "demo")] {
            let field = app.textFields["hostEditor.\(identifier)"]
            field.tap()
            field.typeText(text)
        }
        XCTAssertTrue(test.isEnabled)
        XCTAssertFalse(app.buttons["hostEditor.save"].isEnabled)

        // 有未存的變更時，取消要先確認放棄。
        app.buttons["Cancel"].firstMatch.tap()
        let discard = app.buttons["Discard Changes"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        XCTAssertTrue(app.buttons["hosts.add"].waitForExistence(timeout: 5))
    }

    /// OpenSSH 主機預設用這支裝置的金鑰：公鑰以可選取的文字顯示，有拷貝、分享，以及 macOS／Linux／Windows 的加入指令。
    @MainActor
    func testOpenSSHShowsDevicePublicKeyWithCommands() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)

        chooseOpenSSH(app)
        let publicKey = app.buttons["hostEditor.devicePublicKey"]
        XCTAssertTrue(publicKey.waitForExistence(timeout: 5), "沒有這支裝置的公鑰入口")
        publicKey.tap()

        let keyText = app.staticTexts["deviceKey.publicKey"]
        XCTAssertTrue(keyText.waitForExistence(timeout: 5))
        XCTAssertTrue(keyText.label.hasPrefix("ecdsa-sha2-nistp256 "), "公鑰不是 OpenSSH 一行格式:\(keyText.label)")
        XCTAssertTrue(app.staticTexts["deviceKey.fingerprint"].label.hasPrefix("SHA256:"))
        XCTAssertTrue(app.buttons["deviceKey.copy"].exists)
        XCTAssertTrue(app.buttons["deviceKey.share"].exists)
        // 清單是 lazy:捲動後公鑰那一列可能不在畫面上，先記下文字。
        let key = keyText.label
        for platform in ["macOSAndLinux", "windows", "windowsAdministrator"] {
            let command = app.staticTexts["deviceKey.command.\(platform)"]
            XCTAssertTrue(command.waitForExistence(timeout: 5) || scrollTo(command, in: app), "沒有 \(platform) 的指令")
            XCTAssertTrue(command.label.contains(key), "\(platform) 的指令沒有包含公鑰")
        }
    }

    /// 匯入 RSA 私鑰：說明不支援，並可一鍵改用這支裝置的金鑰。
    @MainActor
    func testImportingRSAKeyOffersDeviceKey() {
        let app = XCUIApplication.launchUITesting()
        openAddHost(app)
        chooseOpenSSH(app)

        app.buttons["hostEditor.signIn"].tap()
        app.buttons["Imported Key"].firstMatch.tap()
        let keyField = app.textViews["hostEditor.privateKey"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText("-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----")

        let problem = app.staticTexts["hostEditor.keyProblem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 5) || scrollTo(problem, in: app))
        XCTAssertTrue(problem.label.contains("RSA"))
        let useDeviceKey = app.buttons["hostEditor.useDeviceKey"]
        XCTAssertTrue(useDeviceKey.exists || scrollTo(useDeviceKey, in: app))
        useDeviceKey.tap()

        XCTAssertTrue(app.buttons["hostEditor.devicePublicKey"].waitForExistence(timeout: 5) || scrollTo(app.buttons["hostEditor.devicePublicKey"], in: app))
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
    private func chooseOpenSSH(_ app: XCUIApplication) {
        let connection = app.buttons["hostEditor.connection"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5) || scrollTo(connection, in: app), "沒有連線方式選單")
        connection.tap()
        let openSSH = app.buttons["OpenSSH"].firstMatch
        XCTAssertTrue(openSSH.waitForExistence(timeout: 5), "沒有 OpenSSH 連線方式")
        openSSH.tap()
    }

    /// 往下捲到元素出現(表單比畫面長)。
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp()
        }
        return element.exists
    }
}
