import XCTest

/// Claude 權限模式(#380):點標題膠囊開面板,下半是勾選列直接切換;非一般模式時膠囊第二行出現模式名。
/// Demo 主機的 Claude 畫面會隨 Shift+Tab 輪替模式標示。
final class PermissionModeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTitlePanelSwitchesModeAndCapsuleShowsIt() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        let header = app.element("conversation.header")
        XCTAssertTrue(header.waitUntilExists(timeout: 10), "沒有標題膠囊")
        XCTAssertFalse(app.element("composer.permissionMode").exists, "輸入列不再有權限模式膠囊")

        header.tap()
        XCTAssertTrue(app.element("status.sheet").waitUntilExists(timeout: 5), "點標題沒有開出面板")
        let picker = app.element("permissionMode.picker")
        XCTAssertTrue(picker.waitUntilExists(timeout: 10), "面板沒有權限模式選項")
        let accept = app.buttons["Accept Edits"].firstMatch
        XCTAssertTrue(accept.waitUntilExists(timeout: 10), "面板裡沒有 Accept Edits 勾選列")
        accept.tap()
        XCTAssertTrue(accept.wait(for: NSPredicate(format: "isSelected == true"), timeout: 10), "沒有切換成 Accept Edits")
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.element("status.sheet").waitUntilGone(timeout: 5))
        XCTAssertTrue(
            header.wait(for: NSPredicate(format: "label CONTAINS 'Accept Edits'"), timeout: 10), "膠囊第二行沒有顯示 Accept Edits")
    }

    /// 模型膠囊(#350):在附加鈕與權限模式膠囊之間;點開 sheet 以勾選列選模型,選定後收起。
    @MainActor
    func testModelCapsuleOpensSheetAndSwitchesModel() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        // 模型膠囊只在輸入列展開(聚焦或有文字)時顯示(#382)。
        app.element("composer.text").tap()
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
        let gone = NSPredicate(format: "exists == false")
        XCTAssertTrue(picker.wait(for: gone, timeout: 10), "等待的條件沒有成立")
    }

    /// Antigravity(#446、#447):標題顯示畫面狀態列讀到的權限模式;狀態面板可切換權限模式(Demo 主機以錄製的輪替順序回應 Shift+Tab);
    /// 模型沒驗證過,面板只顯示、輸入列的模型膠囊顯示「模型 · effort」。
    @MainActor
    func testAntigravitySwitchesModeAndShowsModel() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoAntigravity"])
        let row = app.element("agent.row.demo/w4:p1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 的 Antigravity Agent")
        row.tap()
        let header = app.element("conversation.header")
        XCTAssertTrue(header.waitUntilExists(timeout: 10), "沒有標題膠囊")
        XCTAssertTrue(
            header.wait(for: NSPredicate(format: "label CONTAINS 'Accept Edits'"), timeout: 10), "標題沒有顯示畫面狀態列的 Accept Edits")

        header.tap()
        XCTAssertTrue(app.element("status.sheet").waitUntilExists(timeout: 5), "點標題沒有開出面板")
        XCTAssertTrue(app.element("permissionMode.picker").waitUntilExists(timeout: 10), "面板沒有權限模式選項")
        XCTAssertFalse(app.buttons["Bypass Permissions"].exists, "Antigravity 的輪替沒有略過權限")
        let plan = app.buttons["Plan"].firstMatch
        XCTAssertTrue(plan.waitUntilExists(timeout: 10), "面板裡沒有 Plan 勾選列")
        plan.tap()
        XCTAssertTrue(plan.wait(for: NSPredicate(format: "isSelected == true"), timeout: 10), "沒有切換成 Plan")
        XCTAssertTrue(app.element("status.model").exists, "面板沒有顯示模型")
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.element("status.sheet").waitUntilGone(timeout: 5))
        XCTAssertTrue(header.wait(for: NSPredicate(format: "label BEGINSWITH 'Plan'"), timeout: 10), "標題沒有顯示 Plan")

        app.element("composer.text").tap()
        let capsule = app.element("composer.model")
        XCTAssertTrue(capsule.waitUntilExists(timeout: 10), "沒有模型膠囊")
        XCTAssertTrue((capsule.value as? String ?? "").hasPrefix("Gemini 4 Neon"), "膠囊應顯示 Gemini 4 Neon · effort")
    }
}
