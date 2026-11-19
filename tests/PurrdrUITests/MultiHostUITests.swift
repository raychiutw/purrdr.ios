import XCTest

/// 多主機合併成同一個 Agent 列表(#39)。UI 測試的已存主機通道都是 Demo 主機;`-seedUnreachableHost` 的主機一律連不上。
final class MultiHostUITests: XCTestCase {
    static let studio = "5EED0000-0000-4000-8000-000000000001"
    static let buildBox = "5EED0000-0000-4000-8000-000000000002"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 一台連不上不影響其他台：其他台的列照常顯示(每列預覽前都是主機名，#244),列表下方「主機名：原因」;
    /// 左上角篩選某一台時只剩那台的列，其他台的錯誤行也收起來，選回所有主機就回來。
    @MainActor
    func testUnreachableHostKeepsOtherHostsRows() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnreachableHost"])
        app.switchListMode(to: "Agents")

        let row = element("agent.row.\(Self.studio)/w2:p1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "連不上的主機擋住了其他台的列")
        XCTAssertTrue(row.label.contains("Studio Mac"), "列沒有標示主機名:\(row.label)")
        let error = element("agentList.error.\(Self.buildBox)", in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 15) || scrollTo(error, in: app), "沒有「主機名：原因」")
        XCTAssertTrue(error.label.hasPrefix("Build Box: "), error.label)

        app.collectionViews.firstMatch.swipeDown()
        app.filterHosts("Studio Mac")
        XCTAssertTrue(app.buttons["toolbar.hostFilter"].firstMatch.waitForLabel("Showing: Studio Mac", timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(error.waitForNonExistence(timeout: 5), "篩選 Studio Mac 時不該顯示 Build Box 的錯誤")

        app.filterHosts("All Hosts")
        XCTAssertTrue(error.waitForExistence(timeout: 5) || scrollTo(error, in: app), "選回所有主機後錯誤行沒回來")
    }

    /// 主機篩選(#244):Spaces 檢視只留篩選那台的主機組;篩選選單帶各主機，第一項是所有主機。
    @MainActor
    func testHostFilterLimitsSpaces() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"])
        let demoHeader = element("spaces.host.demo", in: app)
        let studioHeader = element("spaces.host.DE300000-0000-4000-8000-000000000001", in: app)
        XCTAssertTrue(demoHeader.waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons["toolbar.hostFilter"].firstMatch.label, "Showing: All Hosts")

        app.filterHosts("Studio Mac")

        XCTAssertTrue(demoHeader.waitForNonExistence(timeout: 5), "篩選 Studio Mac 時不該有 Demo 的主機組")
        XCTAssertTrue(app.reveal(studioHeader, timeout: 10), "篩選後沒有 Studio Mac 的主機組")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "host-filter-spaces"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// 正式 Demo 也演出多主機(#34):沒有已存主機時，Demo 主機的列之外還有示範主機「Studio Mac」的分組與列,
    /// 列表下方「Build Box: 原因」;主機清單裡沒有示範主機。
    @MainActor
    func testDemoShowsCompanionHosts() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"])

        let studioHeader = element("spaces.host.DE300000-0000-4000-8000-000000000001", in: app)
        XCTAssertTrue(app.reveal(studioHeader, timeout: 20), "沒有示範主機 Studio Mac 的分組")
        XCTAssertTrue(studioHeader.label.hasPrefix("Studio Mac"), studioHeader.label)
        let studioRow = element("agent.row.DE300000-0000-4000-8000-000000000001/w2:p1", in: app)
        XCTAssertTrue(app.reveal(studioRow, timeout: 20), "沒有示範主機 Studio Mac 的列")
        let error = element("agentList.error.DE300000-0000-4000-8000-000000000002", in: app)
        XCTAssertTrue(app.reveal(error, timeout: 20), "沒有連不上的示範主機")
        XCTAssertTrue(error.label.hasPrefix("Build Box: "), error.label)
        XCTAssertEqual(app.buttons["toolbar.hostFilter"].firstMatch.label, "Showing: All Hosts")
    }

    /// 兩台主機有相同的 pane id:各自一列;開非選取中主機的聊天，標題列帶主機名。
    @MainActor
    func testSamePaneOnTwoHostsAreSeparateChats() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-selectDemo"])

        // 「需要你」的 w2:p1 在最上面(列表是 lazy,畫面外的列不在 accessibility tree)。
        let demoRow = element("agent.row.demo/w2:p1", in: app)
        let studioRow = element("agent.row.\(Self.studio)/w2:p1", in: app)
        XCTAssertTrue(demoRow.waitForExistence(timeout: 15))
        XCTAssertTrue(studioRow.waitForExistence(timeout: 15) || scrollTo(studioRow, in: app), "另一台主機同一個 pane 沒有自己的列")

        studioRow.tap()
        let header = element("conversation.header", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("Studio Mac"), "非選取中主機的聊天標題列沒有主機名:\(header.label)")
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
        return element.exists
    }
}

extension XCUIElement {
    /// 等到元素的 accessibility label 變成指定值。
    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
