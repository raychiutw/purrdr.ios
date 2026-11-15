import XCTest

/// 輸入列上方的 slash 選單(#15)。資料來自 Demo 主機的 Claude Code plugin 結構，走正式的發現路徑。
final class SlashMenuUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 打 `/` 出現依來源分組的清單(plugin 宣告的巢狀 skill 在內、停用的 plugin 不在);
    /// 輸入名稱篩選;點選後草稿變成 `/名稱 `、選單收起，鍵盤仍在。
    @MainActor
    func testTypingSlashShowsGroupedMenuAndPicking() {
        let app = XCUIApplication.launchUITesting()
        let row = element("agent.row.demo/w1:p1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("/")

        XCTAssertTrue(element("slash.menu", in: app).waitForExistence(timeout: 10), "打 / 沒有出現選單")
        XCTAssertTrue(element("slash.row.demo-kit:changelog", in: app).waitForExistence(timeout: 10), "plugin 宣告的巢狀 skill 沒有出現")
        XCTAssertTrue(app.staticTexts["demo-kit"].exists, "沒有 plugin 分組標題")
        XCTAssertFalse(app.staticTexts["old-kit"].exists, "停用的 plugin 不該出現")
        XCTAssertTrue(element("slash.row.compact", in: app).exists, "沒有內建指令")

        text.typeText("check")
        XCTAssertTrue(element("slash.row.demo-kit:check-diff", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("slash.row.compact", in: app).exists, "篩選後不該留下不符合的指令")

        element("slash.row.demo-kit:check-diff", in: app).tap()
        XCTAssertEqual(text.value as? String, "/demo-kit:check-diff ")
        XCTAssertFalse(element("slash.menu", in: app).exists, "選取後選單應收起")
        XCTAssertTrue(element("composer.hideKeyboard", in: app).exists, "點選不該收起鍵盤")
    }
}
