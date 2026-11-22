import XCTest

/// 聊天的 A1 浮動膠囊版面(#348,spec #336):玻璃控制浮在內容上、內容延伸到上下邊緣、輸入框與訊息左右對齊。
/// 截圖(淺色、深色、減少透明度)存成附件 `chat-floating-*`。
final class ConversationLayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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

    /// 淺色、深色與減少透明度各存一張截圖(減少透明度:玻璃改不透明底，內容仍可讀)。
    @MainActor
    func testFloatingScreenshots() {
        for (name, flags) in [
            ("light", ["-appearance", "light"]), ("dark", ["-appearance", "dark"]),
            ("reduce-transparency", ["-appearance", "light", "-uiTestingReduceTransparency", "YES"]),
        ] {
            let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: flags)
            XCTAssertTrue(app.element("composer.card").waitUntilExists(timeout: 10), "沒有輸入框卡片(\(name))")
            capture("chat-floating-\(name)")
            app.terminate()
        }
    }
}
