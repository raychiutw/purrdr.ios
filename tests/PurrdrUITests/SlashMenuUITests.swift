import XCTest

/// 輸入列上方的 slash 選單(#15)。資料來自 Demo 主機的 Claude Code plugin 結構，走正式的發現路徑。
final class SlashMenuUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 打 `/` 出現依來源分組的清單(plugin 宣告的巢狀 skill 在內、停用的 plugin 不在);
    /// 輸入名稱後是單一排名清單;點選有副作用的指令(說明提到 commit)只填入 `/名稱 `、選單收起，鍵盤仍在。
    @MainActor
    func testTypingSlashShowsGroupedMenuAndPicking() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row))
        row.tap()

        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        text.typeEnglish("/")

        XCTAssertTrue(app.element("slash.menu").waitUntilExists(timeout: 10), "打 / 沒有出現選單")
        XCTAssertTrue(app.element("slash.row.demo-kit:changelog").waitUntilExists(timeout: 10), "plugin 宣告的巢狀 skill 沒有出現")
        XCTAssertTrue(app.staticTexts["demo-kit"].exists, "沒有 plugin 分組標題")
        XCTAssertFalse(app.staticTexts["old-kit"].exists, "停用的 plugin 不該出現")
        XCTAssertTrue(app.element("slash.row.compact").exists, "沒有內建指令")

        text.typeEnglish("check")
        XCTAssertTrue(app.element("slash.row.demo-kit:check-diff").waitUntilExists(timeout: 5))
        XCTAssertFalse(app.element("slash.row.compact").exists, "篩選後不該留下不符合的指令")
        XCTAssertFalse(app.staticTexts["demo-kit"].exists, "輸入名稱後是單一排名清單，不該有分組標題")

        app.element("slash.row.demo-kit:check-diff").tap()
        XCTAssertEqual(text.value as? String, "/demo-kit:check-diff ")
        XCTAssertFalse(app.element("slash.menu").exists, "選取後選單應收起")
        XCTAssertTrue(app.element("composer.hideKeyboard").exists, "點選不該收起鍵盤")
    }

    /// 文字中間打「空格＋/」:出現只有 skill／自訂指令的選單，點選只換掉 `/字詞`,游標停在插入文字之後可接著打(#230)。
    @MainActor
    func testInlineSlashInsertsSkillKeepingText() {
        let app = XCUIApplication.launchUITesting()
        let text = openLedger(app)
        text.typeEnglish("run /")

        XCTAssertTrue(app.element("slash.row.demo-kit:changelog").waitUntilExists(timeout: 10), "文中打 / 沒有出現 skill")
        XCTAssertFalse(app.element("slash.row.compact").exists, "文中選單不該列內建指令")

        text.typeEnglish("check")
        let row = app.element("slash.row.demo-kit:check-diff")
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        row.tap()
        XCTAssertEqual(text.value as? String, "run /demo-kit:check-diff ")
        XCTAssertFalse(app.element("slash.menu").exists, "選取後選單應收起")

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
            if target.wait(for: done, timeout: 5) { return }
        }
        XCTFail(message)
    }

    @MainActor
    private func openLedger(_ app: XCUIApplication) -> XCUIElement {
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row))
        row.tap()
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        return text
    }

    /// 點選需要參數的指令(`/add-dir <path>`):只填入，游標後提示參數;開始打參數就消失(#45)。
    @MainActor
    func testPickingCommandWithRequiredArgumentShowsHint() {
        let app = XCUIApplication.launchUITesting()
        let text = openLedger(app)
        text.typeEnglish("/add-d")
        let row = app.element("slash.row.add-dir")
        XCTAssertTrue(row.waitUntilExists(timeout: 10))
        row.tap()

        XCTAssertEqual(text.value as? String, "/add-dir ")
        XCTAssertTrue(app.element("composer.argumentHint").waitUntilExists(timeout: 5), "沒有參數提示")
        text.typeEnglish("docs")
        XCTAssertFalse(app.element("composer.argumentHint").exists, "打了參數後提示應消失")
    }

    /// 選定 `/model` 只填入、鍵盤不收起，按送出後聊天內出現面板卡片(#83);點選項移動游標(送方向鍵)、按「Set as default」選定後卡片消失(#45)。
    @MainActor
    func testModelPanelCard() {
        let app = XCUIApplication.launchUITesting()
        let text = openLedger(app)
        text.typeEnglish("/model")
        let row = app.element("slash.row.model")
        XCTAssertTrue(row.waitUntilExists(timeout: 10))
        row.tap()
        XCTAssertEqual(text.value as? String, "/model ")
        XCTAssertTrue(app.element("composer.hideKeyboard").exists, "選定不該收起鍵盤")
        XCTAssertFalse(app.element("panel.card").exists, "選定不該送出")
        app.element("composer.send").tap()

        let card = app.element("panel.card")
        XCTAssertTrue(card.waitUntilExists(timeout: 10), "送出 /model 後沒有出現面板卡片")
        // 收起鍵盤：鍵盤開著時可見範圍很小，卡片上半部可能捲到導覽列底下，點擊會打在導覽列上。
        // 送出就收起鍵盤(#329);還聚焦才點。
        app.dismissKeyboard()
        XCTAssertTrue(app.staticTexts["Select model"].waitUntilExists(timeout: 5))
        let first = app.element("panel.option.0")
        XCTAssertTrue(first.waitUntilExists(timeout: 5))
        app.waitForSettledLayout([card, first], timeout: 3)
        XCTAssertFalse(first.isSelected, "游標一開始在目前的模型(第二列)")
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)

        // 面板卡片在面板監看的輪詢期間可能吃掉點擊：重點到游標移過去。
        tap(first, until: NSPredicate(format: "isSelected == true"), on: first, "點第一列後游標沒有移過去")

        tap(app.element("panel.adjust.right"), until: NSPredicate(format: "exists == true"),
            on: app.staticTexts["◐ High effort"], "←/→ 調整沒有反映")

        tap(app.element("panel.action.enter"), until: NSPredicate(format: "exists == false"), on: card, "選定後卡片沒有消失")
    }

    /// 選定 `/effort` 後按送出 → 面板卡片有攤開的層級列(#83、#313);點層級送方向鍵，按「confirm」後卡片消失(#34)。
    @MainActor
    func testEffortPanelCard() {
        let app = XCUIApplication.launchUITesting()
        let text = openLedger(app)
        text.typeEnglish("/effort")
        let row = app.element("slash.row.effort")
        XCTAssertTrue(row.waitUntilExists(timeout: 10))
        row.tap()
        XCTAssertEqual(text.value as? String, "/effort ")
        app.element("composer.send").tap()

        let card = app.element("panel.card")
        XCTAssertTrue(card.waitUntilExists(timeout: 10), "送出 /effort 後沒有出現面板卡片")
        // 收起鍵盤：鍵盤開著時可見範圍很小，卡片上半部可能捲到導覽列底下，點擊會打在導覽列上。
        // 送出就收起鍵盤(#329);還聚焦才點。
        app.dismissKeyboard()
        XCTAssertTrue(app.staticTexts["Effort"].waitUntilExists(timeout: 5))
        let levels = app.element("panel.levels")
        XCTAssertTrue(levels.waitUntilExists(timeout: 5))
        let xhigh = levels.buttons["xhigh"]
        XCTAssertTrue(xhigh.waitUntilExists(timeout: 5))
        app.waitForSettledLayout([card, xhigh], timeout: 3)
        XCTAssertFalse(xhigh.isSelected, "一開始是 medium")

        tap(xhigh, until: NSPredicate(format: "isSelected == true"), on: xhigh, "點層級沒有反映")

        tap(app.element("panel.action.enter"), until: NSPredicate(format: "exists == false"), on: card, "確認後卡片沒有消失")
    }
}
