import XCTest

/// iPad 帳號頭像在視窗右上角(#520、spec #517):寬視窗掛在最右邊那一欄,四個 tab 一致。
/// 只在 iPad 模擬器跑(完整組)。窄視窗收成一疊(頭像回列表頂列)在 XCUITest 裡縮不了視窗,
/// 決策由 `AccountButtonPlacementTests` 守住,畫面靠手動驗證。
final class IPadAccountUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let isPad = MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad }
        try XCTSkipUnless(isPad, "視窗右上角的頭像只在 iPad 的寬視窗")
    }

    @MainActor
    private func launch(flags: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        return XCUIApplication.launchUITesting(flags: flags)
    }

    /// 頭像在視窗右上區域:靠右邊緣、貼頂列;而且整個畫面只有一顆。
    @MainActor
    private func assertAtWindowTopRight(_ app: XCUIApplication, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let accounts = app.buttons.matching(identifier: "toolbar.account")
        XCTAssertTrue(accounts.firstMatch.waitUntilExists(timeout: 10), "\(context):沒有帳號頭像", file: file, line: line)
        XCTAssertEqual(accounts.count, 1, "\(context):帳號頭像不只一顆", file: file, line: line)
        let window = app.windows.firstMatch.frame
        let frame = accounts.firstMatch.frame
        XCTAssertGreaterThan(frame.maxX, window.maxX - 80, "\(context):頭像不在視窗最右邊 \(frame)", file: file, line: line)
        XCTAssertLessThan(frame.minY, window.minY + 160, "\(context):頭像不在視窗上方 \(frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.width, 44, "\(context):觸控目標小於 44pt", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 44, "\(context):觸控目標小於 44pt", file: file, line: line)
        XCTAssertEqual(accounts.firstMatch.label, "Account", "\(context):VoiceOver 名稱", file: file, line: line)
    }

    /// 聊天 tab 還沒選對話:頭像在最右邊的對話欄右上,不在中間偏左的列表欄,與列表頂列的「＋」不重疊。
    @MainActor
    func testChatsAccountIsInRightmostColumn() {
        let app = launch()
        XCTAssertTrue(app.element("detail.empty").waitUntilExists(timeout: 10), "沒有看到對話欄")
        assertAtWindowTopRight(app, "聊天 tab(沒選對話)")
        let newChat = app.buttons["toolbar.newChat"]
        XCTAssertTrue(newChat.exists, "列表頂列沒有「＋」")
        XCTAssertLessThan(newChat.frame.maxX, app.buttons["toolbar.account"].frame.minX, "頭像與列表頂列的「＋」重疊")
    }

    /// 開了對話之後頭像還在最右上(對話頂列的標題與用量環、「⋯」不把它擠走)。
    @MainActor
    func testAccountStaysAtTopRightWhenChatIsOpen() {
        let app = launch()
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Agent 列表")
        row.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 15), "對話沒有開在對話欄")
        assertAtWindowTopRight(app, "聊天 tab(對話開著)")
    }

    /// 四個 tab 的頭像位置一致(都在視窗右上)。
    @MainActor
    func testAccountIsAtTopRightOnAllFourTabs() {
        let app = launch()
        for tab in ["Chats", "Files", "Hosts", "Traffic"] {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND NOT identifier BEGINSWITH %@", tab, "spaces")).firstMatch
            XCTAssertTrue(button.waitUntilExists(timeout: 10), "沒有 \(tab) tab")
            button.tap()
            assertAtWindowTopRight(app, "\(tab) tab")
        }
    }
}
