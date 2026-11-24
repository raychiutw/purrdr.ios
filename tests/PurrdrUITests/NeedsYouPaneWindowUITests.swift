import XCTest

/// Pane 獨立視窗裡的「需要你」橫幅(#539、spec #528)。只在 iPad 跑(iPhone 沒有多視窗);完整組。
/// 情境 `-demoNeedsYouLater`:打開某個聊天 3 秒後 notes(`w3:p1`)變成需要你。
final class NeedsYouPaneWindowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let isPad = MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad }
        try XCTSkipUnless(isPad, "多視窗只在 iPad")
    }

    /// 在新視窗開 ledger 後 notes 變成需要你:新視窗出現橫幅;點了在主視窗開 notes 的聊天。
    @MainActor
    func testPaneWindowBannerOpensChatInMainWindow() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication.launchUITesting(flags: ["-demoNeedsYouLater"])
        let ledger = app.element(chatRowID("w1:p1"))
        XCTAssertTrue(app.reveal(ledger), "列表沒有 ledger")
        ledger.press(forDuration: 1)
        let newWindow = app.buttons["Open in New Window"]
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5), "選單沒有「Open in New Window」")
        newWindow.tap()
        // 模擬器不一定開得出第二個視窗(Stage Manager 未開時系統只切換場景)：開不出來就略過，不當成失敗。
        Thread.sleep(forTimeInterval: 3)
        try XCTSkipIf(app.windows.count < 2, "模擬器沒有開出第二個視窗，無法驗證 Pane 視窗橫幅")

        let banner = app.element("needsYou.banner")
        XCTAssertTrue(banner.waitUntilExists(timeout: 30), "Pane 視窗沒有出現「需要你」橫幅")
        app.buttons["needsYou.banner.open"].firstMatch.tap()

        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10), "主視窗沒有開出那個聊天")
    }
}
