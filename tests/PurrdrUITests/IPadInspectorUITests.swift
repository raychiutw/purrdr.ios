import XCTest

/// iPad 對話右側 Inspector(#521、spec #517):頂列的鈕開關、內容是「⋯」各 sheet 的同一批內容、在 Inspector 裡直接切權限模式。
/// 只在 iPad 模擬器跑(iPhone 沒有 Inspector 鈕);窄視窗變 sheet 的行為無法在 XCUITest 裡縮小視窗,靠手動驗證。
final class IPadInspectorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let isPad = MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad }
        try XCTSkipUnless(isPad, "Inspector 只在 iPad 的對話欄")
    }

    @MainActor
    private func openChat(flags: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication.launchUITesting(flags: flags)
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Agent 列表")
        row.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 15), "對話沒有開在對話欄")
        return app
    }

    /// 預設(UI 測試)關閉;按頂列的鈕開出右側欄,內容有用量、權限模式;再按一次收起。
    @MainActor
    func testToggleShowsAndHidesInspector() {
        let app = openChat()
        let toggle = app.buttons["conversation.inspectorToggle"]
        XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "對話頂列沒有 Inspector 鈕")
        XCTAssertEqual(toggle.label, "Show Inspector")
        XCTAssertFalse(app.element("inspector").exists, "預設不該開著")

        toggle.tap()

        XCTAssertTrue(app.element("inspector").waitUntilExists(timeout: 5), "按了鈕 Inspector 沒有出現")
        XCTAssertTrue(app.element("inspector.usage").waitUntilExists(timeout: 5), "Inspector 沒有用量")
        XCTAssertTrue(app.buttons["Accept Edits"].firstMatch.waitUntilExists(timeout: 20), "Inspector 沒有權限模式")
        XCTAssertEqual(app.buttons["conversation.inspectorToggle"].label, "Hide Inspector")
        XCTAssertTrue(app.element("composer.text").exists, "Inspector 擠掉了對話")

        app.buttons["conversation.inspectorToggle"].tap()

        XCTAssertTrue(app.element("inspector").waitUntilGone(timeout: 5), "再按一次 Inspector 沒有收起")
    }

    /// 直式(對話欄放不下側欄):偏好是顯示也不自動跳出,按鈕開 sheet,關閉鈕收起,對話不被擠成一條。
    @MainActor
    func testNarrowDetailOpensInspectorAsSheet() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingInspectorShown"])
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Agent 列表")
        row.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 15), "對話沒有開在對話欄")
        XCTAssertFalse(app.element("inspector").exists, "窄的對話欄不該自動開出 Inspector")

        app.buttons["conversation.inspectorToggle"].tap()

        XCTAssertTrue(app.buttons["inspector.close"].waitUntilExists(timeout: 5), "窄的對話欄沒有以 sheet 開出 Inspector")
        app.buttons["inspector.close"].tap()
        XCTAssertTrue(app.buttons["inspector.close"].waitUntilGone(timeout: 5), "關閉鈕沒有收起 sheet")
    }

    /// `-uiTestingInspectorShown`(模擬偏好存著「顯示」):開聊天就看到 Inspector。
    @MainActor
    func testRememberedShownPreferenceOpensInspectorWithChat() {
        let app = openChat(flags: ["-uiTestingInspectorShown"])

        XCTAssertTrue(app.element("inspector").waitUntilExists(timeout: 10), "偏好是顯示,但開聊天沒有看到 Inspector")
        XCTAssertEqual(app.buttons["conversation.inspectorToggle"].label, "Hide Inspector")
    }

    /// 在 Inspector 裡直接切權限模式:行為同 sheet(成功切換),但 Inspector 不會因此關掉。
    @MainActor
    func testSwitchingPermissionModeInsideInspector() {
        let app = openChat(flags: ["-uiTestingInspectorShown"])
        XCTAssertTrue(app.buttons["Accept Edits"].firstMatch.waitUntilExists(timeout: 20), "Inspector 沒有權限模式")
        let accept = app.buttons["Accept Edits"].firstMatch
        XCTAssertTrue(accept.waitUntilExists(timeout: 10), "沒有 Accept Edits 勾選列")

        accept.tap()

        XCTAssertTrue(
            accept.wait(for: NSPredicate(format: "isSelected == true"), timeout: 20), "切換後 Accept Edits 沒有變成選取")
        XCTAssertTrue(app.element("inspector").exists, "切換權限模式把 Inspector 關掉了")
    }
}
