import XCTest

/// 方案用量畫面(#177):從頂部選單打開 → 選 Demo 主機與 Claude Code → 同意 → 兩個用量週期 → 切換已用 → 關閉還原。
/// Demo 主機用範例資料(5 小時已用 38%、每週已用 61%)。Agent 列表不再顯示方案用量。
final class PlanUsageUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func openPlanUsage(_ app: XCUIApplication) {
        XCTAssertTrue(element("agent.row.demo/w2:p1", in: app).waitForExistence(timeout: 10))
        app.buttons["toolbar.more"].tap()
        let item = app.buttons["menu.planUsage"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "頂部選單沒有「方案用量」")
        item.tap()
    }

    @MainActor
    func testConsentShowsPeriodsAndTurnOffRestores() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(element("agent.row.demo/w2:p1", in: app).waitForExistence(timeout: 10))
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertFalse(app.buttons["claudeUsage.show"].exists, "Agent 列表還有方案用量")
        openPlanUsage(app)

        let host = element("planUsage.host", in: app)
        XCTAssertTrue(host.waitForExistence(timeout: 5), "沒有主機選單")
        XCTAssertTrue("\(host.label) \(host.value ?? "")".contains("Demo"), "主機選單不是 Demo:\(host.label)")
        let agent = element("planUsage.agent", in: app)
        XCTAssertTrue("\(agent.label) \(agent.value ?? "")".contains("Claude Code"), "Agent 選單不是 Claude Code:\(agent.label)")

        let consent = app.buttons["planUsage.consent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10), "沒有請使用者同意")
        consent.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "沒有詢問同意")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("settings.json"), "沒說明會改什麼:\(message)")
        XCTAssertTrue(message.contains("demo"), "沒說明以哪個使用者:\(message)")
        alert.buttons["Change Settings"].tap()

        let fiveHour = element("planUsage.period.fiveHour", in: app)
        XCTAssertTrue(fiveHour.waitForExistence(timeout: 10), "沒有 5 小時用量週期")
        XCTAssertTrue(fiveHour.label.contains("62% left"), "5 小時不是剩餘比例:\(fiveHour.label)")
        XCTAssertTrue(fiveHour.label.contains("Resets"), "5 小時沒有重置時間:\(fiveHour.label)")
        let week = element("planUsage.period.week", in: app)
        XCTAssertTrue(week.label.contains("39% left"), "每週不是剩餘比例:\(week.label)")

        element("planUsage.menu", in: app).tap()
        let showUsed = app.buttons["Show Used"]
        XCTAssertTrue(showUsed.waitForExistence(timeout: 5), "選單沒有「Show Used」")
        showUsed.tap()
        let used = NSPredicate(format: "label CONTAINS %@", "38% used")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: used, evaluatedWith: fiveHour)], timeout: 5), .completed,
                       "沒切換成已用比例:\(fiveHour.label)")

        element("planUsage.menu", in: app).tap()
        app.buttons["Turn Off Claude Usage"].tap()
        XCTAssertTrue(app.buttons["planUsage.consent"].waitForExistence(timeout: 10), "關閉後沒有回到請使用者同意")
    }

    @MainActor
    func testCancelConsentChangesNothing() {
        let app = XCUIApplication.launchUITesting()
        openPlanUsage(app)
        let consent = app.buttons["planUsage.consent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
        consent.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()

        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        XCTAssertFalse(element("planUsage.period.fiveHour", in: app).exists)
    }
}
