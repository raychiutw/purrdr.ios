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

        let hostsButton = app.buttons["toolbar.hosts"]
        XCTAssertTrue(hostsButton.waitForExistence(timeout: 10))
        hostsButton.tap()

        let demo = app.buttons["hosts.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        XCTAssertTrue(demo.isSelected, "沒有主機時應選取 Demo 主機")

        app.buttons["hosts.add"].tap()
        let test = app.buttons["hostEditor.test"]
        XCTAssertTrue(test.waitForExistence(timeout: 5))
        XCTAssertFalse(test.isEnabled, "必填欄位沒填就能測試")
        XCTAssertFalse(app.buttons["hostEditor.save"].isEnabled, "沒測試就能儲存")
        XCTAssertTrue(app.staticTexts["Tailscale SSH"].exists)

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
}
