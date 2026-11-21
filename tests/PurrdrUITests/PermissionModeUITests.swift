import XCTest

/// Claude 權限模式膠囊(#306):輸入列工具列、附加鈕右邊;高度同附加鈕,點一下開 sheet 選模式(勾選列)。
/// Demo 主機的 Claude 畫面會隨 Shift+Tab 輪替模式標示。
final class PermissionModeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    func testCapsuleSitsBesideAttachButtonAndSheetSwitchesMode() {
        let app = XCUIApplication.launchUITesting()
        let row = element("agent.row.demo/w1:p1", in: app)
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        let capsule = element("composer.permissionMode", in: app)
        let attach = element("composer.addImage", in: app)
        XCTAssertTrue(capsule.waitForExistence(timeout: 10), "沒有權限模式膠囊")
        XCTAssertGreaterThan(capsule.frame.minX, attach.frame.maxX - 1, "膠囊應在附加鈕右邊")
        XCTAssertEqual(capsule.frame.midY, attach.frame.midY, accuracy: 2, "膠囊應與附加鈕同一列")

        let normal = NSPredicate(format: "value == 'Normal'")
        expectation(for: normal, evaluatedWith: capsule)
        waitForExpectations(timeout: 10)

        capsule.tap()
        let accept = app.buttons["Accept Edits"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "sheet 裡沒有 Accept Edits 勾選列")
        accept.tap()
        let switched = NSPredicate(format: "value == 'Accept Edits'")
        expectation(for: switched, evaluatedWith: capsule)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["permissionMode.done"].exists, "切換成功後 sheet 應收起")

        capsule.tap()
        let plan = app.buttons["Plan"].firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 10))
        plan.tap()
        let planValue = NSPredicate(format: "value == 'Plan'")
        expectation(for: planValue, evaluatedWith: capsule)
        waitForExpectations(timeout: 10)
    }
}
