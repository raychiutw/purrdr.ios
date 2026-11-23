import XCTest

/// 數據用量頁(#354):設定 → 數據用量。種子資料(`-seedDataUsage`):今天與這次開啟共 10 MB(行動網路 2 MB),
/// Studio Mac 過去 29 天每天 23 MB、Build Box 每天 1 MB、已刪除的主機每天 2 MB。
final class DataUsageUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private static let studioID = "5EED0000-0000-4000-8000-000000000001"
    private static let buildID = "5EED0000-0000-4000-8000-000000000002"

    @MainActor
    private func openDataUsage(flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnreachableHost", "-seedDataUsage"] + flags)
        app.openTab(.traffic)
        XCTAssertTrue(app.element("dataUsage.page").waitUntilExists(timeout: 5))
        return app
    }

    @MainActor
    func testSummaryShowsTodayAndLaunchWithCellular() {
        let app = openDataUsage()
        for id in ["dataUsage.sinceLaunch", "dataUsage.today"] {
            let tile = app.element(id)
            XCTAssertTrue(tile.waitUntilExists(timeout: 5), id)
            XCTAssertTrue(tile.label.contains("10 MB"), "\(id) 不是 10 MB:\(tile.label)")
            XCTAssertTrue(tile.label.contains("2 MB"), "\(id) 沒有行動網路 2 MB:\(tile.label)")
        }
        XCTAssertTrue(app.element("dataUsage.chart").exists)
    }

    @MainActor
    func testSwitchPeriodAndCategory() {
        let app = openDataUsage()
        let period = app.buttons["dataUsage.period"]
        XCTAssertTrue(period.label.contains("30 Days"), period.label)
        period.tap()
        let thirty = optionRow("30 Days", in: app)
        XCTAssertTrue(thirty.waitUntilExists(timeout: 5))
        XCTAssertTrue(thirty.isSelected, "預設不是 30 天")
        optionRow("7 Days", in: app).tap()
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.buttons["dataUsage.period"].label.contains("7 Days"))

        app.buttons["dataUsage.category"].tap()
        let total = optionRow("Total", in: app)
        XCTAssertTrue(total.waitUntilExists(timeout: 5))
        XCTAssertTrue(total.isSelected, "預設不是加總")
        optionRow("Sent & Received", in: app).tap()
        app.buttons["sheet.close"].tap()
        let legend = app.element("dataUsage.legend")
        XCTAssertTrue(legend.waitUntilExists(timeout: 5))
        XCTAssertTrue(legend.label.contains("Sent") || app.staticTexts["Sent"].exists, "圖例沒有送出")
        XCTAssertTrue(app.staticTexts["Received"].exists, "圖例沒有收到")
    }

    /// 選項 sheet 裡的勾選列(列帶著 `dataUsage.periodOptions`／`categoryOptions`;膠囊按鈕的標籤也一樣,所以用 identifier 分開)。
    @MainActor
    private func optionRow(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier ENDSWITH 'Options'", label)).firstMatch
    }

}
