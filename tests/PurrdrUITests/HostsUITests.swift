import XCTest

/// 主機清單與主機編輯(UI 測試只用 Demo 主機，不連網路);新增主機的流程在 `AddHostGuideUITests`。
final class HostsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 頁首只有標題(#236):沒有主機時也不在清單最上面放說明文字。
    @MainActor
    func testEmptyHostListShowsOnlyTitle() {
        let app = XCUIApplication.launchUITesting()
        openHosts(app)

        XCTAssertTrue(app.buttons["hosts.demo"].waitUntilExists(timeout: 5))
        let description = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Add a computer that runs herdr"))
        XCTAssertEqual(description.count, 0, "主機清單仍有說明文字")
    }

    static let seededRow = "hosts.row.5EED0000-0000-4000-8000-000000000001"
    static let seededInfo = "hosts.info.5EED0000-0000-4000-8000-000000000001"

    @MainActor
    private func openHosts(_ app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitUntilExists(timeout: 10))
        more.tap()
        let hostsItem = app.buttons["menu.hosts"]
        XCTAssertTrue(hostsItem.waitUntilExists(timeout: 5))
        hostsItem.tap()
    }

    /// 掃 QR code／點分享連結(深層連結)→ 主機 sheet 開出新增主機引導，資料已齊，直接到測試連線，通過後才能加入。
    @MainActor
    func testShareLinkOpensGuideAtTest() throws {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.buttons["toolbar.more"].waitUntilExists(timeout: 10))
        // HostShareLink:name Studio Mac、host studio-mac、port 22、user demo。
        let payload = #"{"host":"studio-mac","method":"tailscaleSSH","name":"Studio Mac","port":22,"user":"demo","v":1}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        app.open(try XCTUnwrap(URL(string: "purrdr://host?d=\(encoded)")))

        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有直接到測試連線\n\(app.debugDescription)")
        save.tap()
        app.buttons["guide.done"].tapWhenReady()
        app.buttons["toolbar.more"].tap()
        app.buttons["menu.hosts"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Studio Mac")).firstMatch.waitUntilExists(timeout: 5),
            "主機清單沒有匯入的主機")
    }

    /// 列尾 ⓘ 開那台主機的編輯器(VoiceOver 念「主機名 詳細資訊」);點列本身仍是選取並關閉 sheet。
    @MainActor
    func testInfoButtonOpensEditor() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openHosts(app)
        let info = app.buttons[Self.seededInfo]
        XCTAssertTrue(info.waitUntilExists(timeout: 5))
        XCTAssertEqual(info.label, "Studio Mac Details")

        info.tap()

        XCTAssertTrue(app.navigationBars["Edit Host"].waitUntilExists(timeout: 5))
        XCTAssertEqual(app.textFields["hostEditor.name"].value as? String, "Studio Mac")
    }

    /// #333:編輯既有主機、點名稱欄叫出鍵盤後，點左上角的 Cancel(iOS 26 顯示成 ×)不能閃退。
    /// 沒改動時直接關閉;改了名稱時先出現放棄確認，確認後回到主機清單。
    @MainActor
    func testCancelEditingSeededHostWithKeyboardUpDoesNotCrash() {
        for flags in [[String](), ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]] {
            for edits in [false, true] {
                let app = XCUIApplication.launchUITesting(flags: ["-seedHost"] + flags)
                openHosts(app)
                let info = app.buttons[Self.seededInfo]
                XCTAssertTrue(info.waitUntilExists(timeout: 5))
                info.tap()
                let name = app.textFields["hostEditor.name"]
                XCTAssertTrue(name.waitUntilExists(timeout: 5))
                name.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitUntilExists(timeout: 5), "沒有叫出鍵盤")
                if edits { name.typeEnglish("2") }

                let cancel = app.navigationBars.buttons.matching(identifier: "Cancel").firstMatch.exists
                    ? app.navigationBars.buttons.matching(identifier: "Cancel").firstMatch
                    : app.navigationBars.buttons.element(boundBy: 0)
                cancel.tap()

                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "點取消後 app 不在前景(閃退) flags=\(flags) edits=\(edits)")
                if edits {
                    let discard = app.buttons["Discard Changes"].firstMatch
                    let discardZh = app.buttons["放棄變更"].firstMatch
                    XCTAssertTrue(UITestWait.until(timeout: 5) { discard.exists || discardZh.exists }, "沒有放棄確認")
                    (discard.exists ? discard : discardZh).tap()
                }
                XCTAssertTrue(app.buttons[Self.seededInfo].waitUntilExists(timeout: 5), "沒有回到主機清單")
                XCTAssertEqual(app.state, .runningForeground)
                app.terminate()
            }
        }
    }

    /// 編輯器的圖示欄位：11 種加「無」;只改圖示不必重新測試連線就能儲存，再開編輯器仍是選的那個。
    @MainActor
    func testEditorChangesHostIconWithoutRetesting() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openHosts(app)
        let info = app.buttons[Self.seededInfo]
        XCTAssertTrue(info.waitUntilExists(timeout: 5))
        info.tap()
        let desktop = app.buttons["hostEditor.icon.desktop"]
        XCTAssertTrue(desktop.waitUntilExists(timeout: 5))
        XCTAssertTrue(desktop.isSelected, "沒選過圖示的主機是桌機")
        for raw in ["laptop", "macMini", "rack", "pc", "display", "board", "console", "home", "cloud", "terminal", "none"] {
            XCTAssertTrue(app.buttons["hostEditor.icon.\(raw)"].exists, raw)
        }

        let board = app.buttons["hostEditor.icon.board"]
        board.tap()
        XCTAssertTrue(board.isSelected)
        XCTAssertFalse(desktop.isSelected)
        let save = app.buttons["hostEditor.save"]
        XCTAssertTrue(save.isEnabled, "只改圖示不必重新測試連線")
        save.tap()

        // 儲存後同一般儲存關閉主機 sheet;再開一次確認圖示存起來了。
        openHosts(app)
        XCTAssertTrue(info.waitUntilExists(timeout: 5))
        info.tap()
        XCTAssertTrue(app.buttons["hostEditor.icon.board"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["hostEditor.icon.board"].isSelected)
    }

    /// 已存的主機：分享(QR code)、重新命名、刪除(先確認，取消就不刪)。
    @MainActor
    func testShareRenameAndDeleteHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openHosts(app)
        let row = app.buttons[Self.seededRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        XCTAssertTrue(row.isSelected, "已存主機應是選取中主機")

        // 分享:在同一個 sheet 內 push,顯示 QR code 與分享連結。
        row.press(forDuration: 1)
        app.buttons["Share…"].firstMatch.tap()
        // `.accessibilityElement()` 讓 QR code 以 Other(而非 Image)出現在 accessibility tree。
        XCTAssertTrue(app.descendants(matching: .any)["hostShare.qr"].firstMatch.waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["hostShare.link"].exists)
        app.navigationBars["Share Host"].buttons["Hosts"].tap()

        // 重新命名。
        if !row.waitUntilExists(timeout: 5) { print(app.debugDescription) }
        XCTAssertTrue(row.exists)
        row.press(forDuration: 1)
        app.buttons["Rename…"].firstMatch.tap()
        // alert 裡的 TextField 不會帶上 SwiftUI 的 accessibilityIdentifier,改從 alert 找。
        let field = app.alerts["Rename Host"].textFields.firstMatch
        XCTAssertTrue(field.waitUntilExists(timeout: 5))
        field.clearAndType("Office Mac")
        app.buttons["hosts.rename.confirm"].firstMatch.tap()
        let renamed = expectation(for: NSPredicate(format: "label CONTAINS %@", "Office Mac"), evaluatedWith: row)
        wait(for: [renamed], timeout: 5)

        // 選單的刪除：先確認，取消就不刪。
        row.press(forDuration: 1)
        app.buttons["Delete…"].firstMatch.tap()
        let confirm = app.buttons["hosts.delete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "刪除主機要先確認")
        // iOS 27 的確認對話框沒有 Cancel 按鈕，點對話框外取消。
        let dismissRegion = app.otherElements["PopoverDismissRegion"].firstMatch
        XCTAssertTrue(dismissRegion.exists, "確認對話框沒有可點外面取消的區域")
        dismissRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(confirm.waitUntilGone(timeout: 5))
        XCTAssertTrue(row.exists, "取消後主機還在")

        // 滑動的刪除：確認後才移除;選取改回 Demo 主機。
        row.swipeLeft()
        app.buttons["hosts.delete"].tap()
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "刪除主機要先確認")
        XCTAssertTrue(row.exists, "確認前不該移除")
        confirm.tap()
        XCTAssertTrue(row.waitUntilGone(timeout: 5))
        XCTAssertTrue(app.buttons["hosts.demo"].isSelected)
    }
}

extension XCUIElement {
    /// 清掉文字欄位原本的內容再輸入。
    @MainActor
    func clearAndType(_ text: String) {
        tap()
        if let value = value as? String, !value.isEmpty {
            typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        typeEnglish(text)
    }
}

