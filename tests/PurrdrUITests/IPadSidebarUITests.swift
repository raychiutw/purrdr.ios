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
        // 對話頂列(用量環)可點才算畫面穩定,再送硬體鍵盤快捷鍵。
        XCTAssertTrue(UITestWait.until(timeout: 10) { app.buttons["conversation.usage"].firstMatch.isHittable }, "對話頂列沒有就緒")
    }

    /// 對話欄的導覽列(不是列表欄的「Chats」那條)。
    @MainActor
    private func detailBackButton(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.matching(NSPredicate(format: "identifier != 'Chats'")).buttons.firstMatch
    }

    /// 版面圖(多 Pane 的 Tab):列表欄的系統選取,版面圖顯示在對話欄、列表欄留著;選版面圖裡的 Pane 就換成那個聊天,
    /// 之後再選別的聊天列也正常(#641:選取列表內不再有推入的連結,沒有「第一下返回被吃掉」)。
    @MainActor
    func testLayoutRowSelectsLayoutInDetailColumn() {
        let app = launch()
        openChat(app)
        let tab = app.element("spaces.tab.demo/w3:t1")
        XCTAssertTrue(app.reveal(tab), "沒有看到多 Pane 的 Tab")

        tab.tap()
        XCTAssertTrue(app.buttons["layout.block.w3:p1"].waitUntilExists(timeout: 5), "點多 Pane 的 Tab 沒有在對話欄顯示版面圖")
        XCTAssertTrue(tab.exists, "版面圖不該把列表欄推走")
        XCTAssertFalse(app.element("composer.text").exists, "對話欄應該換成版面圖")

        app.buttons["layout.block.w3:p1"].tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10), "選版面圖裡的 Agent 沒有開成對話")
        XCTAssertFalse(app.buttons["layout.block.w3:p1"].exists, "對話開了之後版面圖該收起")

        // 再回頭選版面圖、再選別的聊天列。
        tab.tap()
        XCTAssertTrue(app.buttons["layout.block.w3:p1"].waitUntilExists(timeout: 5), "第二次選版面圖沒有顯示")
        let other = app.element("spaces.tab.demo/w2:t1")
        XCTAssertTrue(app.reveal(other))
        other.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10), "選別的聊天列沒有開在對話欄")
        XCTAssertFalse(app.buttons["layout.block.w3:p1"].exists)
    }

    /// 新增聊天推進對話欄的堆疊(#621):列表欄留著;對話欄左上系統返回離開,回到原本的對話。
    @MainActor
    func testNewChatPushesInDetailColumnAndBackKeepsChat() {
        let app = launch()
        openChat(app)

        app.buttons["toolbar.newChat"].firstMatch.tap()
        let page = app.element("newChat.page")
        XCTAssertTrue(page.waitUntilExists(timeout: 10), "新增聊天沒有開出")
        XCTAssertTrue(app.element("spaces.tab.demo/w1:t1").exists, "新增聊天不該把列表欄推走")

        let back = detailBackButton(app)
        XCTAssertTrue(back.waitUntilExists(timeout: 5), "對話欄沒有系統返回")
        back.tap()
        XCTAssertTrue(UITestWait.until(timeout: 5) { !page.exists }, "返回沒有離開新增聊天")
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 5), "返回後沒有回到原本的對話")
    }

    /// Option-Command-, 開帳號與設定:寬視窗是 page sheet(不是全螢幕),關閉後對話欄的對話還在(#623)。
    @MainActor
    func testAppSettingsShortcutOpensPageSheetAndClosesBackToChat() {
        let app = launch()
        openChat(app)

        app.openAccountWithShortcut()
        let sheet = app.element("account.signedOut")
        XCTAssertLessThan(sheet.frame.width, app.windows.firstMatch.frame.width, "寬視窗的帳號與設定應是 page sheet、不是滿版")
        app.closeAccountSheet()
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

    /// 系統的 sidebar 開關(HIG Toolbars:前緣放顯示／隱藏 sidebar;`NavigationSplitView` 預設給,不自己畫也不拿掉):
    /// 點了收起列表欄、對話欄拿到整個視窗,再點一次回來;列表欄的選取不丟。
    @MainActor
    func testSystemSidebarToggleCollapsesAndRestoresListColumn() {
        let app = launch()
        openChat(app)
        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Sidebar'")).firstMatch
        XCTAssertTrue(toggle.waitUntilExists(timeout: 10), "沒有系統的 sidebar 開關\n\(app.debugDescription)")
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(row.isHittable, "收起前列表欄應該看得到")

        toggle.tap()
        XCTAssertTrue(UITestWait.until(timeout: 10) { !row.isHittable }, "點 sidebar 開關後列表欄沒有收起")
        XCTAssertTrue(app.element("composer.text").exists, "收起列表欄後對話不見了")

        toggle.tap()
        XCTAssertTrue(UITestWait.until(timeout: 10) { app.element("spaces.tab.demo/w1:t1").isHittable }, "再點一次列表欄沒有回來")
        XCTAssertTrue(app.element("composer.text").exists, "展開後對話不見了")
    }

    /// 列表欄標題跟系統(iPadOS 26 起 sidebar 預設 inline):標題「Chats」存在、在列表欄範圍內,且不和右側控制項、列表第一列重疊。
    @MainActor
    func testListColumnTitleExistsAndDoesNotOverlap() {
        let app = launch()
        openChat(app)
        let title = app.topBarTitle("Chats")
        XCTAssertTrue(title.waitUntilExists(timeout: 10), "列表欄沒有標題\n\(app.debugDescription)")
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(row.waitUntilExists(timeout: 10))
        let newChat = app.buttons["toolbar.newChat"].firstMatch
        XCTAssertTrue(newChat.waitUntilExists(timeout: 5))
        print("IPADTITLE title=\(title.frame) newChat=\(newChat.frame) row=\(row.frame)")
        XCTAssertGreaterThan(title.frame.width, 0)
        XCTAssertLessThanOrEqual(title.frame.maxX, newChat.frame.minX + 1, "標題和右側控制項重疊")
        XCTAssertLessThanOrEqual(title.frame.maxY, row.frame.minY + 1, "標題和列表第一列重疊")
        XCTAssertLessThan(title.frame.maxX, app.windows.firstMatch.frame.midX, "標題不在左側列表欄")
    }
}
