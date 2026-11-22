import XCTest

/// Claude 權限模式膠囊(#306):輸入列工具列、附加鈕右邊;高度同附加鈕,點一下開 sheet 選模式(勾選列)。
/// Demo 主機的 Claude 畫面會隨 Shift+Tab 輪替模式標示。
final class PermissionModeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCapsuleSitsBesideAttachButtonAndSheetSwitchesMode() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        let capsule = app.element("composer.permissionMode")
        let attach = app.element("composer.attach")
        XCTAssertTrue(capsule.waitUntilExists(timeout: 10), "沒有權限模式膠囊")
        XCTAssertGreaterThan(capsule.frame.minX, attach.frame.maxX - 1, "膠囊應在附加鈕右邊")
        XCTAssertEqual(capsule.frame.midY, attach.frame.midY, accuracy: 2, "膠囊應與附加鈕同一列")

        let normal = NSPredicate(format: "value == 'Normal'")
        XCTAssertTrue(capsule.wait(for: normal, timeout: 10), "等待的條件沒有成立")

        capsule.tap()
        let accept = app.buttons["Accept Edits"].firstMatch
        XCTAssertTrue(accept.waitUntilExists(timeout: 10), "sheet 裡沒有 Accept Edits 勾選列")
        accept.tap()
        let switched = NSPredicate(format: "value == 'Accept Edits'")
        XCTAssertTrue(capsule.wait(for: switched, timeout: 10), "等待的條件沒有成立")
        XCTAssertFalse(app.buttons["permissionMode.done"].exists, "切換成功後 sheet 應收起")

        capsule.tap()
        let plan = app.buttons["Plan"].firstMatch
        XCTAssertTrue(plan.waitUntilExists(timeout: 10))
        plan.tap()
        let planValue = NSPredicate(format: "value == 'Plan'")
        XCTAssertTrue(capsule.wait(for: planValue, timeout: 10), "等待的條件沒有成立")
    }

    /// 模型膠囊(#350):在附加鈕與權限模式膠囊之間;點開 sheet 以勾選列選模型,選定後收起。
    @MainActor
    func testModelCapsuleOpensSheetAndSwitchesModel() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        let capsule = app.element("composer.model")
        let attach = app.element("composer.attach")
        let permission = app.element("composer.permissionMode")
        XCTAssertTrue(capsule.waitUntilExists(timeout: 10), "沒有模型膠囊")
        XCTAssertGreaterThan(capsule.frame.minX, attach.frame.maxX - 1, "模型膠囊應在附加鈕右邊")
        XCTAssertLessThan(capsule.frame.maxX, permission.frame.minX + 1, "模型膠囊應在權限膠囊左邊")
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
}
