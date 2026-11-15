import XCTest

/// 列表底部的 Claude 用量(行為規格 F18):同意 → 顯示 5h／Week → 切換已用 → 關閉還原。Demo 主機用範例資料。
final class ClaudeUsageUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func scrollToBottom(_ app: XCUIApplication, until target: XCUIElement) {
        for _ in 0..<5 where !target.isHittable {
            app.swipeUp()
        }
    }

    @MainActor
    func testConsentShowsUsageAndTurnOffRestores() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(element("agent.row.w1:p1", in: app).waitForExistence(timeout: 10))

        let show = app.buttons["claudeUsage.show"]
        scrollToBottom(app, until: show)
        XCTAssertTrue(show.waitForExistence(timeout: 5), "沒有「顯示 Claude 用量」")
        show.tap()

        // 確認前說明會改什麼、以哪個使用者。
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "沒有詢問同意")
        XCTAssertTrue(alert.label.contains("Claude Usage") || alert.staticTexts.count > 0)
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("settings.json"), "沒說明會改什麼:\(message)")
        XCTAssertTrue(message.contains("demo"), "沒說明以哪個使用者:\(message)")
        alert.buttons["Change Settings"].tap()

        let fiveHour = element("claudeUsage.row.fiveHour", in: app)
        scrollToBottom(app, until: fiveHour)
        XCTAssertTrue(fiveHour.waitForExistence(timeout: 10), "沒有 5h 用量")
        XCTAssertTrue(fiveHour.label.contains("62% left"), "5h 不是剩餘比例:\(fiveHour.label)")
        XCTAssertTrue(fiveHour.label.contains("Resets"), "5h 沒有重置時間:\(fiveHour.label)")
        let week = element("claudeUsage.row.week", in: app)
        XCTAssertTrue(week.label.contains("39% left"), "Week 不是剩餘比例:\(week.label)")

        // 點選項選單切換成已用比例。
        element("claudeUsage.menu", in: app).tap()
        let showUsed = app.buttons["Show Used"]
        XCTAssertTrue(showUsed.waitForExistence(timeout: 5), "選單沒有「Show Used」")
        showUsed.tap()
        let used = NSPredicate(format: "label CONTAINS %@", "38% used")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: used, evaluatedWith: fiveHour)], timeout: 5), .completed,
                       "沒切換成已用比例:\(fiveHour.label)")

        // 關閉：還原主機設定，回到未同意。
        element("claudeUsage.menu", in: app).tap()
        app.buttons["Turn Off Claude Usage"].tap()
        XCTAssertTrue(app.buttons["claudeUsage.show"].waitForExistence(timeout: 10), "關閉後沒有回到「顯示 Claude 用量」")
    }

    @MainActor
    func testCancelConsentChangesNothing() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(element("agent.row.w1:p1", in: app).waitForExistence(timeout: 10))
        let show = app.buttons["claudeUsage.show"]
        scrollToBottom(app, until: show)
        show.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()

        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertFalse(element("claudeUsage.row.fiveHour", in: app).exists)
    }
}
