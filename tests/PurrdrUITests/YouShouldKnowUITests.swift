import XCTest

/// 「You should know」註記與主機主題(#23,#37 故事 49–50)。Demo 主機有一則給 ledger(w1:p1)的註記，herdr 主題是 tokyo-night。
final class YouShouldKnowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 列表的「✦ 1 note for you」→ 註記清單 →「前往」→ 聊天的輸入列上方有註記 →「在聊天中討論」(先同意)
    /// 把註記放進輸入框，註記消失。
    @MainActor
    func testNoteFromListToChatAndDiscuss() {
        let app = XCUIApplication.launchUITesting()
        let summary = app.buttons["youShouldKnow.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "列表沒有註記提示")
        XCTAssertTrue(summary.label.contains("1 note for you"), "提示文字不對:\(summary.label)")
        summary.tap()

        let go = element("youShouldKnow.go.demo/w1:p1", in: app)
        XCTAssertTrue(go.waitForExistence(timeout: 5), "註記清單沒有「前往」")
        go.tap()

        let note = element("youShouldKnow.note", in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 15), "聊天輸入列上方沒有註記")
        XCTAssertTrue(note.label.contains("Decimal keeps cents exact"))
        XCTAssertTrue(app.buttons["youShouldKnow.learnMore"].exists)
        XCTAssertTrue(app.buttons["youShouldKnow.knewIt"].exists)
        XCTAssertTrue(app.buttons["youShouldKnow.dismiss"].exists)

        app.buttons["youShouldKnow.discuss"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "沒有詢問同意")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("demo"), "沒說明以哪個使用者:\(message)")
        alert.buttons["Allow"].firstMatch.tap()

        let editor = app.textViews.firstMatch
        let drafted = NSPredicate(format: "value CONTAINS %@", "Here is a note offered by a side agent")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: drafted, evaluatedWith: editor)], timeout: 5), .completed,
                       "輸入框沒有放入註記")
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: note)], timeout: 10), .completed, "註記沒有消失")
    }

    /// 註記卡片的動作排成一列(略過是標題列右上的 ✕),不直排佔掉對話;註記在時建議卡不同時出現(一次只顯示一樣)。
    @MainActor
    func testNoteActionsShareOneRowAndHideSuggestion() {
        let app = XCUIApplication.launchUITesting()
        let row = element("agent.row.demo/w1:p1", in: app)
        XCTAssertTrue(app.reveal(row, timeout: 15))
        row.tap()

        let note = element("youShouldKnow.note", in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 15), "聊天輸入列上方沒有註記")
        let learnMore = app.buttons["youShouldKnow.learnMore"]
        let knewIt = app.buttons["youShouldKnow.knewIt"]
        let discuss = app.buttons["youShouldKnow.discuss"]
        let dismiss = app.buttons["youShouldKnow.dismiss"]
        for button in [learnMore, knewIt, discuss, dismiss] {
            XCTAssertTrue(button.exists, "註記少了動作 \(button.identifier)")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(button.identifier) 觸控目標不到 44pt")
        }
        XCTAssertEqual(learnMore.frame.midY, knewIt.frame.midY, accuracy: 1, "動作沒有排成一列")
        XCTAssertEqual(knewIt.frame.midY, discuss.frame.midY, accuracy: 1, "動作沒有排成一列")
        XCTAssertLessThan(dismiss.frame.midY, note.frame.minY, "略過不在標題列")
        XCTAssertFalse(element("conversation.suggestion", in: app).exists, "註記與建議卡同時出現")

        dismiss.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "沒有詢問同意")
        alert.buttons["Allow"].firstMatch.tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 10), "略過後註記沒有消失")
        XCTAssertTrue(element("conversation.suggestion", in: app).waitForExistence(timeout: 10), "註記略過後建議卡沒有出現")
    }

    /// 設定頁打開「Use Host Theme」:先同意，之後顯示主機的 herdr 主題名稱;關掉後名稱消失。
    @MainActor
    func testHostThemeToggle() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.reveal(element("agent.row.demo/w1:p1", in: app), timeout: 15))
        app.buttons["toolbar.more"].tap()
        app.buttons["menu.settings"].tap()

        let toggle = app.switches["settings.hostTheme"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "設定頁沒有主機主題開關")
        toggle.switches.firstMatch.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "沒有詢問同意")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("config.toml") && message.contains("demo"), "沒說明讀寫什麼、以哪個使用者:\(message)")
        alert.buttons["Use Theme"].firstMatch.tap()

        let name = element("settings.hostTheme.name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 10), "沒有顯示主機主題")
        XCTAssertTrue(name.label.contains("tokyo-night"), "主題名稱不對:\(name.label)")

        toggle.switches.firstMatch.tap()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: name)], timeout: 10), .completed, "關閉後仍顯示主題")
    }
}
