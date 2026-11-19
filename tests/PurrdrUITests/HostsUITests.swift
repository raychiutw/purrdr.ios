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

    /// 頁首只有標題(#236):沒有主機時也不在清單最上面放說明文字。
    @MainActor
    func testEmptyHostListShowsOnlyTitle() {
        let app = XCUIApplication.launchUITesting()
        openHosts(app)

        XCTAssertTrue(app.buttons["hosts.demo"].waitForExistence(timeout: 5))
        let description = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Add a computer that runs herdr"))
        XCTAssertEqual(description.count, 0, "主機清單仍有說明文字")
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

    static let seededRow = "hosts.row.5EED0000-0000-4000-8000-000000000001"

    @MainActor
    private func openHosts(_ app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let hostsItem = app.buttons["menu.hosts"]
        XCTAssertTrue(hostsItem.waitForExistence(timeout: 5))
        hostsItem.tap()
    }

    /// 掃 QR code／點分享連結(深層連結)→ 主機 sheet 開出帶好欄位的新增主機表單，仍要測試才能儲存。
    @MainActor
    func testShareLinkOpensPrefilledEditor() throws {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.buttons["toolbar.more"].waitForExistence(timeout: 10))
        // HostShareLink:name Studio Mac、host studio-mac、port 22、user demo。
        let payload = #"{"host":"studio-mac","method":"tailscaleSSH","name":"Studio Mac","port":22,"user":"demo","v":1}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        app.open(try XCTUnwrap(URL(string: "purrdr://host?d=\(encoded)")))

        let name = app.textFields["hostEditor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "Studio Mac")
        XCTAssertEqual(app.textFields["hostEditor.address"].value as? String, "studio-mac")
        XCTAssertEqual(app.textFields["hostEditor.username"].value as? String, "demo")
        XCTAssertFalse(app.buttons["hostEditor.save"].isEnabled, "匯入後沒測試就能儲存")
    }

    /// 已存的主機：分享(QR code)、重新命名、刪除(不另外確認)。
    @MainActor
    func testShareRenameAndDeleteHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openHosts(app)
        let row = app.buttons[Self.seededRow]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isSelected, "已存主機應是選取中主機")

        // 分享:在同一個 sheet 內 push,顯示 QR code 與分享連結。
        row.press(forDuration: 1)
        app.buttons["Share…"].firstMatch.tap()
        // `.accessibilityElement()` 讓 QR code 以 Other(而非 Image)出現在 accessibility tree。
        XCTAssertTrue(app.descendants(matching: .any)["hostShare.qr"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["hostShare.link"].exists)
        app.navigationBars["Share Host"].buttons["Hosts"].tap()

        // 重新命名。
        if !row.waitForExistence(timeout: 5) { print(app.debugDescription) }
        XCTAssertTrue(row.exists)
        row.press(forDuration: 1)
        app.buttons["Rename…"].firstMatch.tap()
        // alert 裡的 TextField 不會帶上 SwiftUI 的 accessibilityIdentifier,改從 alert 找。
        let field = app.alerts["Rename Host"].textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearAndType("Office Mac")
        app.buttons["hosts.rename.confirm"].firstMatch.tap()
        let renamed = expectation(for: NSPredicate(format: "label CONTAINS %@", "Office Mac"), evaluatedWith: row)
        wait(for: [renamed], timeout: 5)

        // 刪除：滑動後點一下就刪，不跳確認;選取改回 Demo 主機。
        row.swipeLeft()
        app.buttons["hosts.delete"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists, "刪除主機不該另外確認")
        XCTAssertTrue(app.buttons["hosts.demo"].isSelected)
    }
}

extension XCUIElement {
    /// 清掉文字欄位原本的內容再輸入。
    func clearAndType(_ text: String) {
        tap()
        if let value = value as? String, !value.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        typeText(text)
    }
}
