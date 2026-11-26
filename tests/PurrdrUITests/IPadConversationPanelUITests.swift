import XCTest

/// iPad 聊天頂列用量環開的面板(#617、spec #612):點用量環開 popover,內容是用量加「⋯」各 sheet 的同一批內容,
/// 在面板裡直接切權限模式;頂列沒有 Inspector 開關鈕。
/// 只在 iPad 模擬器跑;窄視窗(compact)變 sheet 的行為無法在 XCUITest 裡縮小視窗,iPhone 的 sheet 由 `ConversationHeaderUITests` 驗。
final class IPadConversationPanelUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let isPad = MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad }
        try XCTSkipUnless(isPad, "popover 版面板只在 iPad 的寬視窗")
    }

    @MainActor
    private func openChat() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication.launchUITesting()
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Agent 列表")
        row.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 15), "對話沒有開在對話欄")
        return app
    }

    /// 頂列沒有 Inspector 開關鈕;點用量環開 popover,有用量與權限模式。
    @MainActor
    func testRingOpensPanelPopover() {
        let app = openChat()
        XCTAssertFalse(app.buttons["conversation.inspectorToggle"].exists, "頂列不該再有 Inspector 開關鈕")
        let ring = app.buttons["conversation.usage"].firstMatch
        XCTAssertTrue(ring.waitUntilExists(timeout: 10), "對話頂列沒有用量環")
        XCTAssertFalse(app.element("conversation.panel").exists, "預設不該開著")

        ring.tap()

        XCTAssertTrue(app.element("conversation.panel").waitUntilExists(timeout: 5), "點用量環沒有開出面板")
        XCTAssertTrue(app.element("usage.sheet.context").waitUntilExists(timeout: 5), "面板沒有用量")
        XCTAssertTrue(app.buttons["Accept Edits"].firstMatch.waitUntilExists(timeout: 20), "面板沒有權限模式")
    }

    /// 在面板裡直接切權限模式:行為同 sheet(成功切換),但面板不會因此關掉。
    @MainActor
    func testSwitchingPermissionModeInsidePanel() {
        let app = openChat()
        app.buttons["conversation.usage"].firstMatch.tap()
        let accept = app.buttons["Accept Edits"].firstMatch
        XCTAssertTrue(accept.waitUntilExists(timeout: 20), "面板沒有權限模式")

        accept.tap()

        XCTAssertTrue(
            accept.wait(for: NSPredicate(format: "isSelected == true"), timeout: 20), "切換後 Accept Edits 沒有變成選取")
        XCTAssertTrue(app.element("conversation.panel").exists, "切換權限模式把面板關掉了")
    }

    /// popover 開著時「⋯」被 popover 蓋住;點外面收掉 popover 後「⋯」選單正常開出(不被剛關掉的 popover 卡住);再開用量環也正常(#617)。
    @MainActor
    func testMoreMenuWorksWhilePanelPopoverIsOpen() {
        let app = openChat()
        let ring = app.buttons["conversation.usage"].firstMatch
        XCTAssertTrue(ring.waitUntilExists(timeout: 10))
        ring.tap()
        XCTAssertTrue(app.element("conversation.panel").waitUntilExists(timeout: 5), "點用量環沒有開出面板")

        // iPadOS 26 的 popover 從來源按鈕「長出來並取代它」(實測:popover 蓋住頂列的用量環與「⋯」,頂端貼著工具列),
        // 所以 popover 開著時「⋯」被蓋住、點不到(不會與選單疊在一起);關閉方式是點外面(系統行為)。
        let more = app.buttons["conversation.more"].firstMatch
        XCTAssertTrue(more.waitUntilExists(timeout: 5), "popover 開著時找不到「⋯」")
        XCTAssertFalse(more.isHittable, "popover 開著時「⋯」不該點得到(會與 popover 疊在一起)")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)).tap()
        XCTAssertTrue(app.element("conversation.panel").waitUntilGone(timeout: 5), "點 popover 外面沒有關掉面板")

        // popover 收掉後再點「⋯」:選單一定要開得出來(不被剛關掉的 popover 卡住)。
        let changes = app.buttons.matching(NSPredicate(format: "identifier == 'changes.open' OR label BEGINSWITH 'Git Changes,'")).firstMatch
        XCTAssertTrue(UITestWait.until(timeout: 5) { more.isHittable }, "popover 關掉後「⋯」點不到")
        more.tap()
        XCTAssertTrue(changes.waitUntilExists(timeout: 5), "popover 收掉後「⋯」選單沒有開出")
        XCTAssertFalse(app.element("conversation.panel").exists, "「⋯」選單開著時面板 popover 不該還在")

        // 關掉選單後,用量環仍可再開面板。
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(changes.waitUntilGone(timeout: 5), "選單沒有關掉")
        ring.tap()
        XCTAssertTrue(app.element("conversation.panel").waitUntilExists(timeout: 5), "選單關掉後用量環開不出面板")
    }
}
