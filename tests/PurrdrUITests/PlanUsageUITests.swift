import XCTest

/// 方案用量畫面(#177):從頂部選單打開 → 選 Demo 主機與 Claude Code → 同意 → 兩個用量週期 → 切換剩餘 → 關閉還原。
/// Demo 主機用範例資料(5 小時已用 38%、每週已用 61%)。Agent 列表不再顯示方案用量。
final class PlanUsageUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 元素自己與裡面所有元素的 label 與 value(選單列的目前選項可能在子元素上)。
    @MainActor
    private func texts(of element: XCUIElement) -> String {
        ([element] + element.descendants(matching: .any).allElementsBoundByIndex)
            .flatMap { [$0.label, ($0.value as? String) ?? ""] }
            .joined(separator: " ")
    }

    @MainActor
    private func openPlanUsage(_ app: XCUIApplication) {
        // 用量擷取的啟用與還原在「這台主機的設定」(#392);已存主機的通道是 Demo 主機,用範例資料。
        app.openSeededHostSettings()
        let item = app.buttons["hosts.settings.usageCapture"]
        XCTAssertTrue(item.waitUntilExists(timeout: 5), "這台主機的設定沒有「用量擷取」")
        item.tap()
    }

    @MainActor
    func testConsentShowsPeriodsAndTurnOffRestores() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        XCTAssertTrue(app.tabBars.firstMatch.waitUntilExists(timeout: 10))
        XCTAssertFalse(app.buttons["claudeUsage.show"].exists, "Agent 列表還有方案用量")
        openPlanUsage(app)

        let host = app.element("planUsage.host")
        XCTAssertTrue(host.waitUntilExists(timeout: 5), "沒有主機選單")
        XCTAssertTrue(texts(of: host).contains("Studio Mac"), "主機選單不是 Studio Mac:\(texts(of: host))")
        // Agent 攤開成勾選列(#313);已用／剩餘在設定 tab(#393),這裡沒有。
        XCTAssertTrue(app.buttons["Claude Code"].isSelected, "Agent 不是 Claude Code")
        XCTAssertFalse(app.element("planUsage.display").exists, "方案用量畫面還有顯示方式選項")

        let consent = app.buttons["planUsage.consent"]
        XCTAssertTrue(consent.waitUntilExists(timeout: 10), "沒有請使用者同意")
        consent.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitUntilExists(timeout: 5), "沒有詢問同意")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("Claude Code setting"), "沒說明會改什麼:\(message)")
        XCTAssertTrue(message.contains("demo"), "沒說明以哪個使用者:\(message)")
        alert.buttons["Change Settings"].tap()

        let fiveHour = app.element("planUsage.period.fiveHour")
        XCTAssertTrue(fiveHour.waitUntilExists(timeout: 10), "沒有 5 小時用量週期")
        XCTAssertTrue(fiveHour.label.contains("38% used"), "5 小時預設不是已用比例(#420):\(fiveHour.label)")
        XCTAssertTrue(fiveHour.label.contains("Resets"), "5 小時沒有重置時間:\(fiveHour.label)")
        let week = app.element("planUsage.period.week")
        XCTAssertTrue(week.label.contains("61% used"), "每週預設不是已用比例(#420):\(week.label)")

        // 在帳號與設定改成剩餘,關掉回來就是剩餘比例(#393、#420、#503)。
        app.openSettingsSheet()
        let showRemaining = app.buttons["Remaining"]
        XCTAssertTrue(app.scrollIntoView(showRemaining), "設定沒有「Remaining」選項")
        showRemaining.tap()
        app.closeAccountSheet()
        app.openTab(.hosts)
        XCTAssertTrue(fiveHour.waitForLabel(containing: "62% left", timeout: 5), "沒切換成剩餘比例:\(fiveHour.label)")

        app.element("planUsage.menu").tap()
        app.buttons["Turn Off Claude Plan Usage"].tap()
        XCTAssertTrue(app.buttons["planUsage.consent"].waitUntilExists(timeout: 10), "關閉後沒有回到請使用者同意")
    }

    @MainActor
    func testCancelConsentChangesNothing() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openPlanUsage(app)
        let consent = app.buttons["planUsage.consent"]
        XCTAssertTrue(consent.waitUntilExists(timeout: 10))
        consent.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitUntilExists(timeout: 5))
        alert.buttons["Cancel"].tap()

        XCTAssertTrue(consent.waitUntilExists(timeout: 5))
        XCTAssertFalse(app.element("planUsage.period.fiveHour").exists)
    }

    /// Demo 主機的 Codex 範例：5 小時已用 24%、每週已用 47%。不需要同意。
    @MainActor
    func testCodexShowsPeriodsWithoutConsent() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openPlanUsage(app)
        let codex = app.buttons["Codex"]
        XCTAssertTrue(codex.waitUntilExists(timeout: 5), "Agent 選項沒有攤開出 Codex")
        codex.tap()

        let fiveHour = app.element("planUsage.period.fiveHour")
        XCTAssertTrue(fiveHour.waitUntilExists(timeout: 10), "沒有 5 小時用量週期")
        XCTAssertTrue(fiveHour.label.contains("24% used"), "5 小時不是 Codex 的範例:\(fiveHour.label)")
        XCTAssertTrue(app.element("planUsage.period.week").label.contains("47% used"), "每週不是 Codex 的範例")
        XCTAssertFalse(app.buttons["planUsage.consent"].exists, "Codex 不該要求同意")
        let note = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Codex reports")).firstMatch
        XCTAssertTrue(note.waitUntilExists(timeout: 5), "說明不是 Codex 的")
    }

    /// Antigravity(#448):Demo 主機的範例有 Gemini 與第三方兩個模型群組;同意後詳細面板兩組都列。
    @MainActor
    func testAntigravityShowsBothModelGroups() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openPlanUsage(app)
        let antigravity = app.buttons["Antigravity"]
        XCTAssertTrue(antigravity.waitUntilExists(timeout: 5), "Agent 選項沒有 Antigravity")
        antigravity.tap()

        let consent = app.buttons["planUsage.consent"]
        XCTAssertTrue(consent.waitUntilExists(timeout: 10), "Antigravity 沒有請使用者同意")
        consent.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitUntilExists(timeout: 5), "沒有詢問同意")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("Antigravity setting"), "沒說明會改什麼:\(message)")
        alert.buttons["Change Settings"].tap()

        let geminiFiveHour = app.element("planUsage.period.gemini.fiveHour")
        XCTAssertTrue(geminiFiveHour.waitUntilExists(timeout: 10), "沒有 Gemini 群組的 5 小時")
        XCTAssertTrue(geminiFiveHour.label.contains("9% used"), "Gemini 5 小時不是範例:\(geminiFiveHour.label)")
        XCTAssertTrue(app.element("planUsage.period.thirdParty.fiveHour").label.contains("40% used"), "第三方 5 小時不是範例")
        XCTAssertTrue(app.element("planUsage.period.thirdParty.week").label.contains("62% used"), "第三方每週不是範例")
        XCTAssertTrue(app.element("planUsage.group.gemini").exists && app.element("planUsage.group.thirdParty").exists, "沒有群組標題")
    }
}
