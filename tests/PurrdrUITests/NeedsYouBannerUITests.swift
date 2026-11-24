import XCTest

/// 聊天頂部的跨聊天「需要你」橫幅(#530、spec #528)。情境旗標 `-demoNeedsYouLater`:打開某個聊天後 3 秒,
/// notes(`w3:p1`)從工作中變成需要你;weather-app(`w2:p1`)一開始就需要你,所以不觸發橫幅。
/// 主流程(出現、點了開那個聊天、返回)在 `DailySmokeUITests.testNeedsYouBanner`。
final class NeedsYouBannerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openLedger(_ app: XCUIApplication) {
        let ledger = app.element(chatRowID("w1:p1"))
        XCTAssertTrue(app.reveal(ledger), "列表沒有 ledger")
        ledger.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10), "沒有進到 ledger 的聊天")
    }

    /// 只有新變成需要你的 notes 觸發;打開聊天時已經需要你的 weather-app 不跳。✕ 收起後不再出現。
    @MainActor
    func testBannerNamesTheNewChatAndDismisses() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoNeedsYouLater"])
        openLedger(app)

        let banner = app.element("needsYou.banner")
        XCTAssertTrue(banner.waitUntilExists(timeout: 20), "別的聊天變成需要你後沒有橫幅")
        let open = app.buttons["needsYou.banner.open"]
        XCTAssertTrue(open.label.hasPrefix("notes — 2 chats need you"), "橫幅沒有寫出最新的 notes 與總數(含一開始就需要你的 weather-app):\(open.label)")
        XCTAssertFalse(open.label.hasPrefix("weather-app"), "打開聊天時已經需要你的不該是觸發橫幅的那個:\(open.label)")

        app.buttons["needsYou.banner.dismiss"].tap()
        XCTAssertTrue(banner.waitUntilGone(timeout: 5), "按 ✕ 後橫幅沒有收起")
        // 收起後同一個轉變不再出現。
        XCTAssertFalse(banner.waitUntilExists(timeout: 4), "收起後同一個轉變又跳出橫幅")
    }

    /// 橫幅停著不會自己消失(HIG:少用限時的介面元素)。
    @MainActor
    func testBannerStaysUntilDismissed() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoNeedsYouLater"])
        openLedger(app)

        let banner = app.element("needsYou.banner")
        XCTAssertTrue(banner.waitUntilExists(timeout: 20), "沒有橫幅")
        // 等超過常見的自動消失時間(toast 約 4~6 秒)後仍在。
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(banner.exists, "橫幅自己消失了")
    }
}
