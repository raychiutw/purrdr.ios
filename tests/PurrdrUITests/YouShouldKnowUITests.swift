import XCTest

/// 「You should know」註記與主機主題(#23,#37 故事 49–50)。Demo 主機有一則給 ledger(w1:p1)的註記，herdr 主題是 tokyo-night。
final class YouShouldKnowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 聊天的輸入列上方有註記 →「在聊天中討論」(先同意)把註記放進輸入框，註記消失。
    /// 列表上不再有註記卡與註記清單(#268,原型沒有);註記只在聊天裡。
    @MainActor
    func testNoteInChatAndDiscuss() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertFalse(app.buttons["youShouldKnow.summary"].exists, "列表不該有註記卡")
        let ledger = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(ledger), "列表沒有 ledger")
        ledger.tap()

        let note = app.element("youShouldKnow.note")
        XCTAssertTrue(note.waitUntilExists(timeout: 15), "聊天輸入列上方沒有註記")
        XCTAssertTrue(note.label.contains("Decimal keeps cents exact"))
        XCTAssertTrue(app.buttons["youShouldKnow.learnMore"].exists)
        XCTAssertTrue(app.buttons["youShouldKnow.knewIt"].exists)
        XCTAssertTrue(app.buttons["youShouldKnow.dismiss"].exists)

        app.buttons["youShouldKnow.discuss"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitUntilExists(timeout: 5), "沒有詢問同意")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("demo"), "沒說明以哪個使用者:\(message)")
        alert.buttons["Allow"].firstMatch.tap()

        let editor = app.textViews.firstMatch
        editor.expectValue(containing: "Here is a note offered by a side agent", timeout: 5)
        XCTAssertTrue(note.waitUntilGone(timeout: 10), "註記沒有消失")
    }

    /// 註記卡片的動作排成一列(略過是標題列右上的 ✕),不直排佔掉對話;註記在時建議卡不同時出現(一次只顯示一樣)。
    @MainActor
    func testNoteActionsShareOneRowAndHideSuggestion() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row, timeout: 15))
        row.tap()

        let note = app.element("youShouldKnow.note")
        XCTAssertTrue(note.waitUntilExists(timeout: 15), "聊天輸入列上方沒有註記")
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
        XCTAssertFalse(app.element("conversation.suggestion").exists, "註記與建議卡同時出現")

        dismiss.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitUntilExists(timeout: 5), "沒有詢問同意")
        alert.buttons["Allow"].firstMatch.tap()
        XCTAssertTrue(note.waitUntilGone(timeout: 10), "略過後註記沒有消失")
        XCTAssertTrue(app.element("conversation.suggestion").waitUntilExists(timeout: 10), "註記略過後建議卡沒有出現")
    }

    /// 主機頁(#274)打開「Use Host Theme」:先同意，之後顯示主機的 herdr 主題名稱;關掉後名稱消失。
    @MainActor
    func testHostThemeToggle() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        app.openSeededHostSettings()

        let toggle = app.switches["settings.hostTheme"]
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "這台主機的設定沒有主機主題開關")
        toggle.switches.firstMatch.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitUntilExists(timeout: 5), "沒有詢問同意")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("colors") && message.contains("demo"), "沒說明讀寫什麼、以哪個使用者:\(message)")
        alert.buttons["Use Theme"].firstMatch.tap()

        let name = app.element("settings.hostTheme.name")
        XCTAssertTrue(name.waitUntilExists(timeout: 10), "沒有顯示主機主題")
        XCTAssertTrue(name.label.contains("tokyo-night"), "主題名稱不對:\(name.label)")

        toggle.switches.firstMatch.tap()
        XCTAssertTrue(name.waitUntilGone(timeout: 10), "關閉後仍顯示主題")
    }
}
