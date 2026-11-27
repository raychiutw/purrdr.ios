import XCTest

/// Claude 權限模式(#380、#515):「⋯」→ 權限模式開 sheet,勾選列直接切換、成功自動關閉;非一般模式時膠囊第二行出現模式名。
/// Demo 主機的 Claude 畫面會隨 Shift+Tab 輪替模式標示。
final class PermissionModeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // 模型膠囊(#350)的檢查在 SlashMenuUITests.testSlashMenuInlineSlashModelPanelAndModelCapsule。

    /// Antigravity(#446、#447):標題顯示畫面狀態列讀到的權限模式;狀態面板可切換權限模式(Demo 主機以錄製的輪替順序回應 Shift+Tab);
    /// 模型沒驗證過,面板只顯示、輸入列的模型膠囊顯示「模型 · effort」。
    @MainActor
    func testAntigravitySwitchesModeAndShowsModel() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoAntigravity"])
        let row = app.element("spaces.tab.demo/w4:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 的 Antigravity Agent")
        row.tap()
        XCTAssertTrue(app.conversationBar.waitUntilExists(timeout: 10), "沒有聊天頂列")
        // 權限模式不在標題(#618),在「⋯」的權限模式項目上看得到畫面狀態列的 Accept Edits。
        let modelItem = app.conversationMoreItem("menu.model")
        let modeItem = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Permission Mode,")).firstMatch
        XCTAssertTrue(modeItem.exists && modeItem.label.contains("Accept Edits"), "「⋯」沒有顯示畫面狀態列的 Accept Edits:\(modeItem.label)")
        XCTAssertTrue(modelItem.label.contains("Gemini 4 Neon"), "「⋯」的模型與思考深度項目沒有顯示目前模型")
        modelItem.tap()
        XCTAssertTrue(app.element("model.current").waitUntilExists(timeout: 15), "Antigravity 的模型 sheet 應只顯示目前模型")
        app.element("model.close").tap()
        XCTAssertTrue(app.element("model.current").waitUntilGone(timeout: 5))
        app.conversationMoreItem("menu.permissionMode").tap()
        XCTAssertTrue(app.element("menu.sheet.permissionMode").waitUntilExists(timeout: 5), "「⋯」→ 權限模式沒有開出 sheet")
        XCTAssertTrue(app.element("permissionMode.picker").waitUntilExists(timeout: 10), "面板沒有權限模式選項")
        XCTAssertFalse(app.buttons["Bypass Permissions"].exists, "Antigravity 的輪替沒有略過權限")
        let plan = app.buttons["Plan"].firstMatch
        XCTAssertTrue(plan.waitUntilExists(timeout: 10), "面板裡沒有 Plan 勾選列")
        plan.tap()
        XCTAssertTrue(app.element("menu.sheet.permissionMode").waitUntilGone(timeout: 15), "切換成功後 sheet 沒有自動關閉")
        XCTAssertTrue(app.conversationMoreItem("menu.permissionMode").label.contains("Plan"), "「⋯」的權限模式副標沒有顯示 Plan")

        app.expandComposer()
        let capsule = app.element("composer.model")
        XCTAssertTrue(capsule.waitUntilExists(timeout: 10), "沒有模型膠囊")
        XCTAssertTrue((capsule.value as? String ?? "").hasPrefix("Gemini 4 Neon"), "膠囊應顯示 Gemini 4 Neon · effort")
    }
}
