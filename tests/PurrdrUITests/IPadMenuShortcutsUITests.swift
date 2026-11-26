import XCTest

/// iPad 選單列的快捷鍵(#522、spec #517):Command-1 到 4 切 tab、Option-Command-I 開關聊天面板。
/// 選單項目的清單與停用條件在單元測試(`KeyboardMenuTests`);這裡驗硬體鍵盤真的觸發。
final class IPadMenuShortcutsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let isPad = MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad }
        try XCTSkipUnless(isPad, "選單列只在 iPad")
    }

    @MainActor
    func testShortcutsSwitchTabsAndToggleConversationPanel() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication.launchUITesting()
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Agent 列表")
        row.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 15), "對話沒有開在對話欄")

        // Option-Command-I:開聊天面板(用量環的面板),再按一次收起。
        XCTAssertFalse(app.element("conversation.panel").exists, "預設不該開著")
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(app.element("conversation.panel").waitUntilExists(timeout: 5), "Option-Command-I 沒有開出面板")
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(UITestWait.until(timeout: 5) { !app.element("conversation.panel").exists }, "再按一次沒有收起面板")

        // Command-2、3、4、1:切到檔案、主機、流量、聊天。
        for (key, label) in [("2", "Files"), ("3", "Hosts"), ("4", "Traffic"), ("1", "Chats")] {
            app.typeKey(key, modifierFlags: .command)
            // iPad 寬視窗的 tab bar 是浮動工具列,不在 `tabBars` 底下(同 `openTab`)。
            let tab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            XCTAssertTrue(
                UITestWait.until(timeout: 5) { tab.exists && tab.isSelected }, "Command-\(key) 沒有切到 \(label)")
        }
    }
}
