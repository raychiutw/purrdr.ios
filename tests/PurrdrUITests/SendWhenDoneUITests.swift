import XCTest

/// Send When Done(#305):HTTPS 主機的聊天輸入列有「做完再送」開關,開著時送出的訊息排進主機的佇列,
/// 對話最下面依序顯示,可往前或往後移動調整送出順序。UI 測試的主機服務替身把佇列放在記憶體。
final class SendWhenDoneUITests: XCTestCase {
    /// `-seedPairedHTTPSHost` 的 HTTPS 主機 id(畫面看到 Demo 的 Agent)。
    static let httpsHost = "5EED0000-0000-4000-8000-000000000006"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func queue(_ text: String, in app: XCUIApplication) {
        let field = app.element("composer.text")
        field.tap()
        field.typeEnglish(text)
        app.element("composer.send").tap()
    }

    @MainActor
    private func queuedTexts(in app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).matching(identifier: "conversation.sendWhenDone.item").allElementsBoundByIndex.map(\.label)
    }

    // 不能用的原因寫在開關下方(#626)的檢查在 ShellCommandUITests.testShellCommandShowsHintAndBlock。

    @MainActor
    func testQueuedMessagesCanBeReordered() throws {
        let app = XCUIApplication.launchUITesting(flags: ["-seedPairedHTTPSHost"])
        let row = app.element("spaces.tab.\(Self.httpsHost)/w1:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 HTTPS 主機的 Agent")
        row.tap()
        // 開關在「⋯」→ 做完再送的 sheet(#515),不在輸入列。
        XCTAssertFalse(app.element("composer.sendWhenDone").exists, "輸入列不該再有做完再送開關")
        let header = app.conversationBar
        XCTAssertTrue(header.waitUntilExists(timeout: 10))
        app.conversationMoreItem("menu.sendWhenDone").tap()
        let toggle = app.element("status.sendWhenDone")
        XCTAssertTrue(toggle.waitUntilExists(timeout: 10), "做完再送 sheet 沒有開關")
        // 系統開關:主機服務的佇列可用性讀回來之前是停用的,等到能打開為止(停用時原因寫在下方,不跳對話框)。
        XCTAssertTrue(UITestWait.until(timeout: 15) { toggle.isEnabled }, "做完再送開關一直是停用")
        XCTAssertEqual(app.alerts.count, 0, "不該用對話框說明")
        // 系統開關:點的是列尾的開關本體(點列的其他地方不會切換,與系統設定相同)。
        let knob = toggle.switches.firstMatch
        knob.tap()
        XCTAssertTrue(UITestWait.until(timeout: 10) { "\(knob.value ?? "")" == "1" }, "做完再送沒有開啟:\(String(describing: knob.value))")
        app.buttons["sheet.close"].tap()

        queue("first message", in: app)
        queue("second message", in: app)
        let items = app.descendants(matching: .any).matching(identifier: "conversation.sendWhenDone.item")
        XCTAssertTrue(UITestWait.until(timeout: 10) { items.count == 2 }, "佇列沒有兩則")
        XCTAssertTrue(queuedTexts(in: app)[0].contains("first message"))
        XCTAssertTrue(queuedTexts(in: app)[1].contains("second message"))

        items.element(boundBy: 1).tap()
        let moveUp = app.element("conversation.sendWhenDone.moveUp")
        XCTAssertTrue(moveUp.waitUntilExists(timeout: 5), "選單沒有往前移動")
        XCTAssertFalse(app.element("conversation.sendWhenDone.moveDown").exists, "最後一則不能再往後")
        moveUp.tap()

        let reordered = NSPredicate(format: "label CONTAINS 'second message'")
        XCTAssertTrue(items.element(boundBy: 0).wait(for: reordered, timeout: 10), "等待的條件沒有成立")
        XCTAssertTrue(queuedTexts(in: app)[1].contains("first message"), "順序沒有對調:\(queuedTexts(in: app))")
    }
}
