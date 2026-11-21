import XCTest

/// 機密偵測(#302):送出像含有密鑰的訊息時，底部升起說明 sheet(類別與行號，不顯示內容);
/// 「返回編輯」放回輸入框，「仍要送出」照常送出。Demo 主機走正式程式路徑。
final class SecretCheckUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    func testSecretShowsSheetThenBackToEditingOrSendAnyway() {
        let app = XCUIApplication.launchUITesting()
        let row = element("agent.row.demo/w1:p1", in: app)
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        let text = element("composer.text", in: app)
        let send = element("composer.send", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10), "沒有輸入框")
        let message = "Deploy with DB_PASSWORD=hunter2024"

        text.tap()
        text.typeEnglish(message)
        send.tap()

        let sheet = element("secretCheck.sheet", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "沒有跳出機密偵測的說明")
        let finding = element("secretCheck.finding.password", in: app)
        XCTAssertTrue(finding.exists, "沒有列出偵測到的類別")
        XCTAssertTrue(finding.label.contains("Line 1"), "沒有說明在第幾行：\(finding.label)")
        XCTAssertFalse(sheet.label.contains("hunter2024"), "說明不應顯示內容本身")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'hunter2024'")).firstMatch.exists,
                       "說明不應顯示內容本身")

        element("secretCheck.backToEditing", in: app).tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "返回編輯後 sheet 應關閉")
        XCTAssertEqual(text.value as? String, message, "返回編輯應把文字放回輸入框")

        send.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "再送一次應再確認")
        element("secretCheck.sendAnyway", in: app).tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "仍要送出後 sheet 應關閉")
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", message)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "仍要送出後應送出這則訊息")
        XCTAssertNotEqual(text.value as? String, message, "送出後輸入框應清空")
    }
}
