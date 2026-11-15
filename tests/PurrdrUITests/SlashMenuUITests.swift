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
    /// 輸入名稱後是單一排名清單;點選有副作用的指令(說明提到 commit)只填入 `/名稱 `、選單收起，鍵盤仍在。
    @MainActor
    func testTypingSlashShowsGroupedMenuAndPicking() {
        let app = XCUIApplication.launchUITesting()
        let row = element("agent.row.w1:p1", in: app)
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
        XCTAssertFalse(app.staticTexts["demo-kit"].exists, "輸入名稱後是單一排名清單，不該有分組標題")

        element("slash.row.demo-kit:check-diff", in: app).tap()
        XCTAssertEqual(text.value as? String, "/demo-kit:check-diff ")
        XCTAssertFalse(element("slash.menu", in: app).exists, "選取後選單應收起")
        XCTAssertTrue(element("composer.hideKeyboard", in: app).exists, "點選不該收起鍵盤")
    }

    @MainActor
    private func openLedger(_ app: XCUIApplication) -> XCUIElement {
        let row = element("agent.row.w1:p1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        return text
    }

    /// 點選需要參數的指令(`/add-dir <path>`):只填入，游標後提示參數;開始打參數就消失(#45)。
    @MainActor
    func testPickingCommandWithRequiredArgumentShowsHint() {
        let app = XCUIApplication.launchUITesting()
        let text = openLedger(app)
        text.typeText("/add-d")
        let row = element("slash.row.add-dir", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        XCTAssertEqual(text.value as? String, "/add-dir ")
        XCTAssertTrue(element("composer.argumentHint", in: app).waitForExistence(timeout: 5), "沒有參數提示")
        text.typeText("docs")
        XCTAssertFalse(element("composer.argumentHint", in: app).exists, "打了參數後提示應消失")
    }

    /// `/model` 直接送出 → 聊天內出現面板卡片;點選項移動游標(送方向鍵)、按「Set as default」選定後卡片消失(#45)。
    @MainActor
    func testModelPanelCard() {
        let app = XCUIApplication.launchUITesting()
        let text = openLedger(app)
        text.typeText("/model")
        let row = element("slash.row.model", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let card = element("panel.card", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "送出 /model 後沒有出現面板卡片")
        XCTAssertTrue(app.staticTexts["Select model"].exists)
        let first = element("panel.option.0", in: app)
        XCTAssertTrue(first.exists)
        XCTAssertFalse(first.isSelected, "游標一開始在目前的模型(第二列)")
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)

        first.tap()
        let moved = NSPredicate(format: "isSelected == true")
        expectation(for: moved, evaluatedWith: first)
        waitForExpectations(timeout: 10)

        element("panel.adjust.right", in: app).tap()
        XCTAssertTrue(app.staticTexts["◐ High effort"].waitForExistence(timeout: 10), "←/→ 調整沒有反映")

        element("panel.action.enter", in: app).tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: card)
        waitForExpectations(timeout: 10)
    }
}
