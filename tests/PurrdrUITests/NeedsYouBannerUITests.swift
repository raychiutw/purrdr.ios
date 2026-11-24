import XCTest

/// 聊天頂部的跨聊天「需要你」橫幅(#530、spec #528)。情境旗標 `-demoNeedsYouLater`:打開某個聊天後 3 秒,
/// notes(`w3:p1`)從工作中變成需要你;weather-app(`w2:p1`)一開始就需要你,所以不觸發橫幅。
/// 主流程(出現、點了開那個聊天、返回後列表置頂段落)串在 `DailySmokeUITests.testListAndChat`;這裡是分支(完整組)。
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

    /// 上滑收起(HIG 的「滑掉」手勢,與 ✕ 等效);收起後同一個轉變不再出現。
    @MainActor
    func testSwipeUpDismissesTheBanner() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoNeedsYouLater"])
        openLedger(app)

        let banner = app.element("needsYou.banner")
        XCTAssertTrue(banner.waitUntilExists(timeout: 20), "別的聊天變成需要你後沒有橫幅")
        banner.swipeUp()

        XCTAssertTrue(banner.waitUntilGone(timeout: 5), "上滑後橫幅沒有收起")
        XCTAssertFalse(banner.waitUntilExists(timeout: 4), "收起後同一個轉變又跳出橫幅")
    }

    /// 有多個需要你時點橫幅進到「最新」那個(notes),不是一開始就需要你的 weather-app。
    @MainActor
    func testBannerOpensTheNewestChat() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoNeedsYouLater"])
        openLedger(app)

        let open = app.buttons["needsYou.banner.open"]
        XCTAssertTrue(open.waitUntilExists(timeout: 20), "沒有橫幅")
        XCTAssertTrue(open.label.contains("2 chats need you"), "橫幅沒有寫出多個:\(open.label)")
        open.tap()

        let header = app.element("conversation.header")
        XCTAssertTrue(header.wait(for: NSPredicate(format: "label CONTAINS 'notes'"), timeout: 10), "點橫幅沒有進到最新的 notes:\(header.label)")
        XCTAssertFalse(header.label.contains("weather-app"), "開到一開始就需要你的 weather-app:\(header.label)")
    }

    /// 與對話的狀態橫幅(`conversation.banner`)並存時上下排列、不互相蓋住。
    /// Demo 的情境旗標互斥,這個情境下 ledger 沒有狀態橫幅,所以只在兩者同時存在時比對位置,否則略過。
    @MainActor
    func testBannerDoesNotOverlapStatusBanner() throws {
        let app = XCUIApplication.launchUITesting(flags: ["-demoNeedsYouLater"])
        openLedger(app)

        let banner = app.element("needsYou.banner")
        XCTAssertTrue(banner.waitUntilExists(timeout: 20), "沒有橫幅")
        let status = app.descendants(matching: .any)["conversation.banner"].firstMatch
        try XCTSkipUnless(status.exists, "這個情境沒有對話狀態橫幅,無法驗證並存")
        XCTAssertLessThanOrEqual(status.frame.maxY, banner.frame.minY + 1, "「需要你」橫幅蓋住了狀態橫幅")
    }

    /// 返回列表後:段落標題標為 header 且念出數量,轉變的那列念出「剛剛」(VoiceOver 讀的是 label)。
    @MainActor
    func testSectionAnnouncesCountAndJustNow() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoNeedsYouLater"])
        openLedger(app)
        XCTAssertTrue(app.element("needsYou.banner").waitUntilExists(timeout: 20), "沒有橫幅")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let header = app.element("needsYou.section")
        XCTAssertTrue(header.waitUntilExists(timeout: 10), "返回後沒有「需要你」段落")
        XCTAssertTrue(header.wait(for: NSPredicate(format: "label CONTAINS '2 chats need you'"), timeout: 10), "標題沒有念出數量:\(header.label)")
        let notes = app.element("needsYou.tab.demo/w3:t1")
        XCTAssertTrue(notes.waitUntilExists(timeout: 5), "段落裡沒有 notes")
        XCTAssertTrue(notes.label.contains("Just now"), "轉變的那列沒有念出「剛剛」:\(notes.label)")
        let weather = app.element("needsYou.tab.demo/w2:t1")
        XCTAssertTrue(weather.waitUntilExists(timeout: 5), "段落裡沒有 weather-app")
        XCTAssertFalse(weather.label.contains("Just now"), "一開始就需要你的不該標「剛剛」:\(weather.label)")
    }
}
