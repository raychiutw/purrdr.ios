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
        let row = element("agent.row.demo/w1:p1", in: app)
        XCTAssertTrue(app.reveal(row))
        row.tap()

        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeEnglish("/")

        XCTAssertTrue(element("slash.menu", in: app).waitForExistence(timeout: 10), "打 / 沒有出現選單")
        XCTAssertTrue(element("slash.row.demo-kit:changelog", in: app).waitForExistence(timeout: 10), "plugin 宣告的巢狀 skill 沒有出現")
        XCTAssertTrue(app.staticTexts["demo-kit"].exists, "沒有 plugin 分組標題")
        XCTAssertFalse(app.staticTexts["old-kit"].exists, "停用的 plugin 不該出現")
        XCTAssertTrue(element("slash.row.compact", in: app).exists, "沒有內建指令")

        text.typeEnglish("check")
        XCTAssertTrue(element("slash.row.demo-kit:check-diff", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("slash.row.compact", in: app).exists, "篩選後不該留下不符合的指令")
        XCTAssertFalse(app.staticTexts["demo-kit"].exists, "輸入名稱後是單一排名清單，不該有分組標題")

        element("slash.row.demo-kit:check-diff", in: app).tap()
        XCTAssertEqual(text.value as? String, "/demo-kit:check-diff ")
        XCTAssertFalse(element("slash.menu", in: app).exists, "選取後選單應收起")
        XCTAssertTrue(element("composer.hideKeyboard", in: app).exists, "點選不該收起鍵盤")
    }

    /// 文字中間打「空格＋/」:出現只有 skill／自訂指令的選單，點選只換掉 `/字詞`,游標停在插入文字之後可接著打(#230)。
    @MainActor
    func testInlineSlashInsertsSkillKeepingText() {
        let app = XCUIApplication.launchUITesting()
        let text = openLedger(app)
        text.typeEnglish("run /")

        XCTAssertTrue(element("slash.row.demo-kit:changelog", in: app).waitForExistence(timeout: 10), "文中打 / 沒有出現 skill")
        XCTAssertFalse(element("slash.row.compact", in: app).exists, "文中選單不該列內建指令")

        text.typeEnglish("check")
        let row = element("slash.row.demo-kit:check-diff", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertEqual(text.value as? String, "run /demo-kit:check-diff ")
        XCTAssertFalse(element("slash.menu", in: app).exists, "選取後選單應收起")

        text.typeEnglish("then fix")
        XCTAssertEqual(text.value as? String, "run /demo-kit:check-diff then fix")
    }

    /// 點面板卡片上的控制項，直到 `done` 成立。
    ///
    /// 卡片在送鍵期間整張停用(`isOperatingPanel`),但畫面可能已經先反映上一次操作(面板監看的輪詢比送鍵的回應早到，
    /// 分段控制也會先自己改選取),這時的點擊會被吃掉。重點一次以上是安全的：←/→ 到底會停住，卡片消失後就不再點。
    @MainActor
    private func tap(_ control: XCUIElement, until done: NSPredicate, on target: XCUIElement, _ message: String) {
        for _ in 0..<3 {
            control.tap()
            if XCTWaiter.wait(for: [expectation(for: done, evaluatedWith: target)], timeout: 5) == .completed { return }
        }
        XCTFail(message)
    }

    @MainActor
    private func openLedger(_ app: XCUIApplication) -> XCUIElement {
        let row = element("agent.row.demo/w1:p1", in: app)
        XCTAssertTrue(app.reveal(row))
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
        text.typeEnglish("/add-d")
        let row = element("slash.row.add-dir", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        XCTAssertEqual(text.value as? String, "/add-dir ")
        XCTAssertTrue(element("composer.argumentHint", in: app).waitForExistence(timeout: 5), "沒有參數提示")
        text.typeEnglish("docs")
        XCTAssertFalse(element("composer.argumentHint", in: app).exists, "打了參數後提示應消失")
    }

    /// 選定 `/model` 只填入、鍵盤不收起，按送出後聊天內出現面板卡片(#83);點選項移動游標(送方向鍵)、按「Set as default」選定後卡片消失(#45)。
    @MainActor
    func testModelPanelCard() {
        let app = XCUIApplication.launchUITesting()
        let text = openLedger(app)
        text.typeEnglish("/model")
        let row = element("slash.row.model", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertEqual(text.value as? String, "/model ")
        XCTAssertTrue(element("composer.hideKeyboard", in: app).exists, "選定不該收起鍵盤")
        XCTAssertFalse(element("panel.card", in: app).exists, "選定不該送出")
        element("composer.send", in: app).tap()

        let card = element("panel.card", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "送出 /model 後沒有出現面板卡片")
        // 收起鍵盤：鍵盤開著時可見範圍很小，卡片上半部可能捲到導覽列底下，點擊會打在導覽列上。
        element("composer.hideKeyboard", in: app).tap()
        XCTAssertTrue(app.staticTexts["Select model"].exists)
        let first = element("panel.option.0", in: app)
        XCTAssertTrue(first.exists)
        XCTAssertFalse(first.isSelected, "游標一開始在目前的模型(第二列)")
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)

        first.tap()
        let moved = NSPredicate(format: "isSelected == true")
        expectation(for: moved, evaluatedWith: first)
        waitForExpectations(timeout: 10)

        tap(element("panel.adjust.right", in: app), until: NSPredicate(format: "exists == true"),
            on: app.staticTexts["◐ High effort"], "←/→ 調整沒有反映")

        tap(element("panel.action.enter", in: app), until: NSPredicate(format: "exists == false"), on: card, "選定後卡片沒有消失")
    }

    /// 選定 `/effort` 後按送出 → 面板卡片有攤開的層級列(#83、#313);點層級送方向鍵，按「confirm」後卡片消失(#34)。
    @MainActor
    func testEffortPanelCard() {
        let app = XCUIApplication.launchUITesting()
        let text = openLedger(app)
        text.typeEnglish("/effort")
        let row = element("slash.row.effort", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertEqual(text.value as? String, "/effort ")
        element("composer.send", in: app).tap()

        let card = element("panel.card", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "送出 /effort 後沒有出現面板卡片")
        // 收起鍵盤：鍵盤開著時可見範圍很小，卡片上半部可能捲到導覽列底下，點擊會打在導覽列上。
        element("composer.hideKeyboard", in: app).tap()
        XCTAssertTrue(app.staticTexts["Effort"].exists)
        let levels = element("panel.levels", in: app)
        XCTAssertTrue(levels.exists)
        let xhigh = levels.buttons["xhigh"]
        XCTAssertTrue(xhigh.exists)
        XCTAssertFalse(xhigh.isSelected, "一開始是 medium")

        tap(xhigh, until: NSPredicate(format: "isSelected == true"), on: xhigh, "點層級沒有反映")

        tap(element("panel.action.enter", in: app), until: NSPredicate(format: "exists == false"), on: card, "確認後卡片沒有消失")
    }
}
