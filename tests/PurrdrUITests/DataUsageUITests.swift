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
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func openDataUsage(flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnreachableHost", "-seedDataUsage"] + flags)
        XCTAssertTrue(app.buttons["toolbar.more"].waitForExistence(timeout: 10))
        app.buttons["toolbar.more"].tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "頂部選單沒有設定")
        settings.tap()
        let entry = app.buttons["settings.dataUsage"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "設定沒有數據用量")
        entry.tap()
        XCTAssertTrue(element("dataUsage.page", in: app).waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    func testSummaryShowsTodayAndLaunchWithCellular() {
        let app = openDataUsage()
        for id in ["dataUsage.sinceLaunch", "dataUsage.today"] {
            let tile = element(id, in: app)
            XCTAssertTrue(tile.waitForExistence(timeout: 5), id)
            XCTAssertTrue(tile.label.contains("10 MB"), "\(id) 不是 10 MB:\(tile.label)")
            XCTAssertTrue(tile.label.contains("2 MB"), "\(id) 沒有行動網路 2 MB:\(tile.label)")
        }
        XCTAssertTrue(element("dataUsage.chart", in: app).exists)
    }

    @MainActor
    func testSwitchPeriodAndCategory() {
        let app = openDataUsage()
        let period = app.buttons["dataUsage.period"]
        XCTAssertTrue(period.label.contains("30 Days"), period.label)
        period.tap()
        let thirty = optionRow("30 Days", in: app)
        XCTAssertTrue(thirty.waitForExistence(timeout: 5))
        XCTAssertTrue(thirty.isSelected, "預設不是 30 天")
        optionRow("7 Days", in: app).tap()
        app.buttons["sheet.done"].tap()
        XCTAssertTrue(app.buttons["dataUsage.period"].label.contains("7 Days"))

        app.buttons["dataUsage.category"].tap()
        let total = optionRow("Total", in: app)
        XCTAssertTrue(total.waitForExistence(timeout: 5))
        XCTAssertTrue(total.isSelected, "預設不是加總")
        optionRow("Sent & Received", in: app).tap()
        app.buttons["sheet.done"].tap()
        let legend = element("dataUsage.legend", in: app)
        XCTAssertTrue(legend.waitForExistence(timeout: 5))
        XCTAssertTrue(legend.label.contains("Sent") || app.staticTexts["Sent"].exists, "圖例沒有送出")
        XCTAssertTrue(app.staticTexts["Received"].exists, "圖例沒有收到")
    }

    @MainActor
    func testTapBarShowsThatDay() {
        let app = openDataUsage()
        let chart = element("dataUsage.chart", in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertFalse(element("dataUsage.selection", in: app).exists)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(element("dataUsage.selection", in: app).waitForExistence(timeout: 5), "點長條沒有出現那天的數字")
    }

    @MainActor
    func testHostRowsAndDetailSheet() {
        let app = openDataUsage()
        let studio = app.buttons["dataUsage.host.\(Self.studioID)"]
        XCTAssertTrue(app.buttons["dataUsage.host.\(Self.buildID)"].exists || scrollTo(app.buttons["dataUsage.host.\(Self.buildID)"], in: app))
        XCTAssertTrue(scrollTo(studio, in: app))
        studio.tap()
        let detail = element("dataUsage.hostDetail", in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Received"].exists)
        XCTAssertTrue(app.staticTexts["Sent"].exists)
        XCTAssertTrue(app.staticTexts["Cellular"].exists)
    }

    @MainActor
    func testHostCapsuleFiltersAndPersistsCurrentHost() {
        let app = openDataUsage()
        let capsule = app.buttons["dataUsage.host"]
        XCTAssertTrue(capsule.label.contains("All Computers"), capsule.label)
        capsule.tap()
        let studio = app.buttons["Studio Mac"]
        XCTAssertTrue(studio.waitForExistence(timeout: 5))
        studio.tap()
        XCTAssertTrue(app.buttons["dataUsage.host"].label.contains("Studio Mac"))
        XCTAssertFalse(app.buttons["dataUsage.host.\(Self.buildID)"].exists, "選了 Studio Mac 還列出 Build Box")
        // 目前主機是全 app 的:關掉設定回到列表,再開還是 Studio Mac。
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["sheet.done"].tap()
        app.buttons["toolbar.more"].tap()
        app.buttons["menu.settings"].tap()
        app.buttons["settings.dataUsage"].tap()
        XCTAssertTrue(app.buttons["dataUsage.host"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dataUsage.host"].label.contains("Studio Mac"))
    }

    @MainActor
    func testResetAsksForConfirmation() {
        let app = openDataUsage()
        let reset = app.buttons["dataUsage.reset"]
        XCTAssertTrue(scrollTo(reset, in: app))
        reset.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "dataUsage.resetConfirm").firstMatch.waitForExistence(timeout: 5))
        // 點對話框外面收起(不確認)。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.3)).tap()
        XCTAssertTrue(app.buttons.matching(identifier: "dataUsage.resetConfirm").firstMatch.waitForNonExistence(timeout: 5), "對話框沒收起")
        XCTAssertTrue(element("dataUsage.today", in: app).label.contains("10 MB"), "取消後數字不該變")

        reset.tap()
        let confirm = app.buttons.matching(identifier: "dataUsage.resetConfirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let today = element("dataUsage.today", in: app)
        XCTAssertTrue(today.label.contains("Zero"), "重設後今天不是 0:\(today.label)")
    }

    /// 選項 sheet 裡的勾選列(列帶著 `dataUsage.periodOptions`／`categoryOptions`;膠囊按鈕的標籤也一樣,所以用 identifier 分開)。
    @MainActor
    private func optionRow(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier ENDSWITH 'Options'", label)).firstMatch
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        return element.exists
    }
}
