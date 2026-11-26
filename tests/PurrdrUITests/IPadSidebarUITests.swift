import XCTest

/// iPad 寬視窗(`NavigationSplitView`)的列表欄與對話欄互動(缺口批次 G1:#621、#623、#624、#641):
/// 列表欄包在自己的 `NavigationStack`,版面圖與新增聊天推進「列表那一欄」、返回只退列表欄,對話欄不被動到;
/// slash 面板在寬視窗的輸入列取代輸入框。只在 iPad 模擬器跑。
final class IPadSidebarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let isPad = MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad }
        try XCTSkipUnless(isPad, "寬視窗的列表欄與對話欄只在 iPad")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        return XCUIApplication.launchUITesting()
    }

    @MainActor
    private func openChat(_ app: XCUIApplication, _ id: String = "spaces.tab.demo/w1:t1") {
        let row = app.element(id)
        XCTAssertTrue(app.reveal(row), "沒有看到 Agent 列表")
        row.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 15), "對話沒有開在對話欄")
    }

    /// 版面圖(多 Pane 的 Tab)推進列表欄:系統返回一次就回到列表,對話欄的對話不受影響;
    /// 返回後點別的聊天列仍能換對話(#641:選取列表內的 NavigationLink 返回行為)。
    @MainActor
    func testLayoutPushesInListColumnAndBackReturnsInOneTap() {
        let app = launch()
        openChat(app)
        let tab = app.element("spaces.tab.demo/w3:t1")
        XCTAssertTrue(app.reveal(tab), "沒有看到多 Pane 的 Tab")

        tab.tap()
        XCTAssertTrue(app.buttons["layout.block.w3:p1"].waitUntilExists(timeout: 5), "點多 Pane 的 Tab 沒有推出版面圖")
        XCTAssertTrue(app.element("composer.text").exists, "推版面圖不該動到對話欄")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(UITestWait.until(timeout: 5) { tab.exists && !app.buttons["layout.block.w3:p1"].exists }, "返回一次沒有回到列表")
        XCTAssertTrue(app.element("composer.text").exists, "返回後對話欄不見了")

        // 再推再退一次(第一下返回被吃掉的問題會在第二輪才看得出來)。
        tab.tap()
        XCTAssertTrue(app.buttons["layout.block.w3:p1"].waitUntilExists(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(UITestWait.until(timeout: 5) { tab.exists && !app.buttons["layout.block.w3:p1"].exists }, "第二次返回沒有回到列表")

        // 返回後點別的聊天列:對話欄換內容。
        let other = app.element("spaces.tab.demo/w2:t1")
        XCTAssertTrue(app.reveal(other))
        other.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10), "返回後點聊天列沒有開在對話欄")
    }

    /// 新增聊天推進列表欄(#621):對話欄原本的對話留著;「<」回到列表,對話欄不變。
    @MainActor
    func testNewChatPushesInListColumnAndBackKeepsChat() {
        let app = launch()
        openChat(app)

        app.buttons["toolbar.newChat"].firstMatch.tap()
        let page = app.element("newChat.page")
        XCTAssertTrue(page.waitUntilExists(timeout: 10), "新增聊天沒有開出")
        XCTAssertTrue(app.element("composer.text").exists, "新增聊天不該蓋掉對話欄")
        XCTAssertFalse(app.element("spaces.tab.demo/w1:t1").exists, "新增聊天應推進列表欄、把列表推走")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(UITestWait.until(timeout: 5) { !page.exists }, "「<」沒有離開新增聊天")
        XCTAssertTrue(app.element("spaces.tab.demo/w1:t1").waitUntilExists(timeout: 5), "回到的不是列表")
        XCTAssertTrue(app.element("composer.text").exists, "返回後對話欄不見了")
    }

    /// Command-, 開帳號與設定(滿版 cover)後關閉,對話欄的對話還在(#623)。
    @MainActor
    func testCommandCommaCoverClosesBackToChat() {
        let app = launch()
        openChat(app)

        app.typeKey(",", modifierFlags: .command)
        app.waitForAccountSheet()
        let close = app.buttons["member.close"].firstMatch
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "帳號頁沒有關閉鈕")
        close.tap()
        XCTAssertTrue(UITestWait.until(timeout: 5) { app.buttons["toolbar.account"].firstMatch.isHittable }, "關閉後底下頁面點不到")
        XCTAssertTrue(app.element("composer.text").exists, "關閉帳號頁後對話不見了")
    }

    /// slash 面板在寬視窗的輸入列:選 `/model` 送出後輸入框換成面板,X 取消後輸入框回來(#624)。
    @MainActor
    func testSlashPanelReplacesComposerOnWideWindow() {
        let app = launch()
        openChat(app)
        let text = app.element("composer.text")
        text.tap()
        text.typeEnglish("/model")
        let row = app.element("slash.row.model")
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "打 /model 沒有選單")
        row.tap()
        app.element("composer.send").tap()

        let bar = app.element("panel.bar")
        XCTAssertTrue(bar.waitUntilExists(timeout: 10), "送出 /model 後輸入框沒有變成面板")
        XCTAssertTrue(UITestWait.until(timeout: 10) { app.buttons["panel.cancel"].isHittable }, "面板的 X 點不到")
        XCTAssertTrue(app.buttons["panel.confirm"].isHittable, "面板的 ✓ 點不到")
        app.buttons["panel.cancel"].tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 5), "取消後輸入框沒有回來")
    }
}
