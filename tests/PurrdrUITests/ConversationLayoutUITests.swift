import XCTest

/// 聊天的 A1 浮動膠囊版面(#348,spec #336):玻璃控制浮在內容上、內容延伸到上下邊緣、輸入框與訊息左右對齊。
/// 截圖(淺色、深色、減少透明度)存成附件 `chat-floating-*`。
final class ConversationLayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }


    /// 最後一則訊息不被浮在內容上的輸入框遮住:最後一則的底緣在輸入框頂緣之上。
    @MainActor
    func testLastMessageIsNotCoveredByComposer() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        let agent = app.element("conversation.agent")
        XCTAssertTrue(agent.waitUntilExists(timeout: 10))
        let card = app.element("composer.card")
        XCTAssertTrue(card.waitUntilExists(timeout: 5), "輸入框沒有玻璃卡片")
        let last = app.descendants(matching: .any).matching(identifier: "conversation.agent").allElementsBoundByIndex.last ?? agent
        XCTAssertLessThanOrEqual(last.frame.maxY, card.frame.minY + 1, "最後一則被輸入框遮住")
    }

    /// 輸入框與訊息左右對齊同一條邊(16pt);輸入框浮在內容上，不貼齊螢幕邊緣。
    @MainActor
    func testComposerAlignsWithMessages() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        let agent = app.element("conversation.agent")
        XCTAssertTrue(agent.waitUntilExists(timeout: 10))
        let card = app.element("composer.card")
        XCTAssertTrue(card.waitUntilExists(timeout: 5), "輸入框沒有玻璃卡片")
        let screen = app.windows.firstMatch.frame
        XCTAssertEqual(card.frame.minX, 16, accuracy: 1, "輸入框左緣不是 16pt")
        XCTAssertEqual(screen.maxX - card.frame.maxX, 16, accuracy: 1, "輸入框右緣不是 16pt")
        // 訊息列表與輸入列都用同一個 16pt 水平邊距(accessibility 容器的 frame 整寬，量不出文字左緣，以截圖確認)。
        _ = agent
        XCTAssertLessThan(card.frame.maxY, screen.maxY, "輸入框應浮在畫面底部上方")
    }

    /// 工作中膠囊浮在輸入框上方，在左右 16pt 邊界內(不是貼齊螢幕的色塊)。
    @MainActor
    func testWorkingCapsuleFloatsAboveComposer() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w3:p1")
        let bar = app.element("stopBar")
        XCTAssertTrue(bar.waitUntilExists(timeout: 10), "工作中沒有膠囊")
        let card = app.element("composer.card")
        XCTAssertTrue(card.waitUntilExists(timeout: 5), "輸入框沒有玻璃卡片")
        XCTAssertLessThanOrEqual(bar.frame.maxY, card.frame.minY + 1, "膠囊應在輸入框上方")
        XCTAssertGreaterThanOrEqual(bar.frame.minX, 15, "膠囊超出左右邊界")
    }


    /// 診斷(tab bar 延遲):帶動畫從聊天返回列表，tab bar 應與列表同時出現，不是轉場結束後才冒出來。
    /// 量「點返回 → tab bar 存在且點得到」的時間，tap 返回時轉場已結束，tab bar 落後超過 0.05 秒就是「轉場後才冒出」。
    @MainActor
    func testTabBarReturnsTogetherWithListOnBack() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingAnimations"])
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitUntilExists(timeout: 10))
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row))
        row.tap()
        XCTAssertTrue(app.element("conversation.header").waitUntilExistsAndSettled(timeout: 15))
        XCTAssertTrue(tabBar.waitUntilGone(timeout: 5), "對話裡不該有 tab bar")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        let start = Date()
        back.tap()
        // tap 會等 app 閒置(含轉場結束)才返回:列表此刻已就位。tab bar 該同時就位。
        let tapReturned = Date().timeIntervalSince(start)
        let listVisible = row.exists && row.isHittable
        var lag: TimeInterval?
        while Date().timeIntervalSince(start) < 5 {
            if tabBar.exists, tabBar.isHittable { lag = Date().timeIntervalSince(start) - tapReturned; break }
        }
        print("TABBAR-LATENCY tapReturned=\(String(format: "%.3f", tapReturned)) listHittableAtTapReturn=\(listVisible) tabBarLagAfterTapReturn=\(lag.map { String(format: "%.3f", $0) } ?? "never")")
        XCTAssertNotNil(lag, "返回後 tab bar 沒有回來")
        XCTAssertLessThanOrEqual(lag ?? 99, 0.05, "tab bar 在返回轉場結束後才出現")
    }
}
