import XCTest

/// 機密偵測(#302):送出像含有密鑰的訊息時，底部升起說明 sheet(類別與行號，不顯示內容);
/// 「返回編輯」放回輸入框，「仍要送出」照常送出。Demo 主機走正式程式路徑。
final class SecretCheckUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSecretShowsSheetThenBackToEditingOrSendAnyway() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        let text = app.element("composer.text")
        let send = app.element("composer.send")
        XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
        let message = "Deploy with DB_PASSWORD=hunter2024"

        text.tap()
        text.typeEnglish(message)
        send.tap()

        let sheet = app.element("secretCheck.sheet")
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "沒有跳出機密偵測的說明")
        let finding = app.element("secretCheck.finding.password")
        XCTAssertTrue(finding.exists, "沒有列出偵測到的類別")
        XCTAssertTrue(finding.label.contains("Line 1"), "沒有說明在第幾行：\(finding.label)")
        XCTAssertFalse(sheet.label.contains("hunter2024"), "說明不應顯示內容本身")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'hunter2024'")).firstMatch.exists,
                       "說明不應顯示內容本身")

        app.element("secretCheck.backToEditing").tap()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "返回編輯後 sheet 應關閉")
        XCTAssertEqual(text.value as? String, message, "返回編輯應把文字放回輸入框")

        send.tap()
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "再送一次應再確認")
        app.element("secretCheck.sendAnyway").tap()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "仍要送出後 sheet 應關閉")
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", message)).firstMatch
        XCTAssertTrue(sent.waitUntilExists(timeout: 10), "仍要送出後應送出這則訊息")
        XCTAssertNotEqual(text.value as? String, message, "送出後輸入框應清空")
    }
}
