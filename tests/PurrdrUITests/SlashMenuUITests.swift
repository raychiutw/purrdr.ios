import XCTest

/// 輸入列上方的 slash 選單(#15)。資料來自 Demo 主機的 Claude Code plugin 結構，走正式的發現路徑。
final class SlashMenuUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// (單一啟動,原本 4 個測試合併)打 `/` 出現依來源分組的清單(plugin 宣告的巢狀 skill 在內、停用的 plugin 不在);
    /// 輸入名稱後是單一排名清單;點選有副作用的指令(說明提到 commit)只填入 `/名稱 `、選單收起，鍵盤仍在。
    @MainActor
    func testSlashMenuInlineSlashModelPanelAndModelCapsule() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("spaces.tab.demo/w1:t1")
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
        XCTAssertTrue(app.element("slash.menu").waitUntilGone(timeout: 5), "選取後選單應收起")
        XCTAssertTrue(text.hasKeyboardFocus, "點選不該收起鍵盤")

        // 文字中間打「空格＋/」:出現只有 skill／自訂指令的選單，點選只換掉 `/字詞`,游標停在插入文字之後可接著打(#230)。
        text.clearAndType("run /")
        XCTAssertTrue(app.element("slash.row.demo-kit:changelog").waitUntilExists(timeout: 10), "文中打 / 沒有出現 skill")
        XCTAssertFalse(app.element("slash.row.compact").exists, "文中選單不該列內建指令")
        text.typeEnglish("check")
        let inlineRow = app.element("slash.row.demo-kit:check-diff")
        XCTAssertTrue(inlineRow.waitUntilExists(timeout: 5))
        inlineRow.tap()
        XCTAssertEqual(text.value as? String, "run /demo-kit:check-diff ")
        XCTAssertTrue(app.element("slash.menu").waitUntilGone(timeout: 5), "選取後選單應收起")
        text.typeEnglish("then fix")
        XCTAssertEqual(text.value as? String, "run /demo-kit:check-diff then fix")

        // 選定 `/model` 只填入、鍵盤不收起,按送出後輸入框變成面板(#624):輸入框不在、面板佔住鍵盤位置,左 X 與右 ✓ 可操作;
        // 點選項移動游標(送方向鍵)、調整 effort、按 ✓ 選定後面板收起、輸入框回來(#45)。
        text.clearAndType("/model")
        let modelRow = app.element("slash.row.model")
        XCTAssertTrue(modelRow.waitUntilExists(timeout: 10))
        modelRow.tap()
        XCTAssertEqual(text.value as? String, "/model ")
        XCTAssertTrue(text.hasKeyboardFocus, "選定不該收起鍵盤")
        XCTAssertFalse(app.element("panel.bar").waitUntilExists(timeout: 1), "選定不該送出")
        app.element("composer.send").tap()
        let bar = app.element("panel.bar")
        XCTAssertTrue(bar.waitUntilExists(timeout: 10), "送出 /model 後輸入框沒有變成面板")
        XCTAssertFalse(app.element("composer.text").exists, "面板出現時輸入框要收起")
        XCTAssertTrue(app.buttons["panel.cancel"].exists, "沒有左 X")
        XCTAssertTrue(app.buttons["panel.confirm"].exists, "沒有右 ✓")
        XCTAssertTrue(app.staticTexts["Select model"].waitUntilExists(timeout: 5))
        // Picker 的識別碼套在每一列(系統行為),第一列用順序找。
        let first = app.buttons.matching(identifier: "panel.options").element(boundBy: 0)
        XCTAssertTrue(first.waitUntilExists(timeout: 5))
        app.waitForSettledLayout([bar, first], timeout: 3)
        XCTAssertFalse(first.isSelected, "游標一開始在目前的模型(第二列)")
        // 面板佔住鍵盤位置:對話整段在面板上方,不被蓋住。
        XCTAssertGreaterThan(bar.frame.height, 200, "面板高度應同鍵盤")

        // 面板在監看的輪詢期間可能吃掉點擊:重點到游標移過去。
        tap(first, until: { $0.isSelected }, on: first, "點第一列後游標沒有移過去")

        let stepper = app.steppers["panel.adjustment"]
        XCTAssertTrue(scrollPanel(app, to: stepper), "沒有 ←/→ 調整")
        tap(stepper.buttons.element(boundBy: 1), until: { $0.exists },
            on: app.staticTexts["◐ High effort"], "←/→ 調整沒有反映")

        tap(app.buttons["panel.confirm"], until: { !$0.exists }, on: bar, "選定後面板沒有消失")
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 5), "面板收起後輸入框沒有回來")

        // 左 X = Esc:不改設定,面板收起、輸入框回來(#624)(同一次啟動,再開一次 /model)。
        text.tap()
        text.typeEnglish("/model")
        app.element("slash.row.model").tap()
        app.element("composer.send").tap()
        XCTAssertTrue(bar.waitUntilExists(timeout: 10))
        XCTAssertFalse(app.element("composer.text").exists)
        tap(app.buttons["panel.cancel"], until: { !$0.exists }, on: bar, "按 X 後面板沒有消失")
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 5), "面板收起後輸入框沒有回來")

        // 模型膠囊(#350):在附加鈕與權限模式膠囊之間;點開 sheet 以勾選列選模型,選定後收起(放最後,避免改了模型影響面板游標)。
        // 模型膠囊只在輸入列展開(第二行、換行或附件,#512)時顯示。
        app.expandComposer()
        let capsule = app.element("composer.model")
        let attach = app.element("composer.attach")
        XCTAssertTrue(capsule.waitUntilExists(timeout: 10), "沒有模型膠囊")
        XCTAssertGreaterThan(capsule.frame.minX, attach.frame.maxX - 1, "模型膠囊應在附加鈕右邊")
        XCTAssertEqual(capsule.frame.midY, attach.frame.midY, accuracy: 2, "模型膠囊應與附加鈕同一列")
        XCTAssertFalse((capsule.value as? String ?? "").isEmpty, "膠囊應顯示目前的模型")

        capsule.tap()
        let picker = app.element("model.picker")
        XCTAssertTrue(picker.waitUntilExists(timeout: 15), "sheet 裡沒有模型勾選列")
        let quick = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Quick'")).firstMatch
        XCTAssertTrue(quick.waitUntilExists(timeout: 10), "sheet 裡沒有 Quick 勾選列")
        quick.tap()
        XCTAssertTrue(picker.waitUntilGone(timeout: 10), "選定模型後 sheet 沒有收起")
    }

    /// 點面板卡片上的控制項，直到 `done` 成立。
    ///
    /// 卡片在送鍵期間整張停用(`isOperatingPanel`),但畫面可能已經先反映上一次操作(面板監看的輪詢比送鍵的回應早到，
    /// 分段控制也會先自己改選取),這時的點擊會被吃掉。重點一次以上是安全的：←/→ 到底會停住，卡片消失後就不再點。
    /// 面板的清單比面板矮(鍵盤高度)時,往上捲到目標出現(清單是 lazy,畫面外的列不在 accessibility tree)。
    @MainActor
    private func scrollPanel(_ app: XCUIApplication, to target: XCUIElement) -> Bool {
        for _ in 0..<4 {
            if target.waitUntilExists(timeout: 2) { return true }
            app.element("panel.card").swipeUp()
        }
        return target.exists
    }

    @MainActor
    private func tap(_ control: XCUIElement, until done: (XCUIElement) -> Bool, on target: XCUIElement, _ message: String) {
        for _ in 0..<3 {
            control.tap()
            if target.wait(timeout: 5, until: done) { return }
        }
        XCTFail(message)
    }
}
