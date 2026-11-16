import XCTest

/// 多主機合併成同一個 Agent 列表(#39)。UI 測試的已存主機通道都是 Demo 主機;`-seedUnreachableHost` 的主機一律連不上。
final class MultiHostUITests: XCTestCase {
    static let studio = "5EED0000-0000-4000-8000-000000000001"
    static let lab = "5EED0000-0000-4000-8000-000000000002"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 一台連不上不影響其他台：連不上的是選取中主機時，其他台的列照常顯示(標示主機名),列表下方「主機名：原因」;
    /// 用頂部主機鈕換選取中主機後，列不再標示主機名，錯誤行仍在。
    @MainActor
    func testUnreachableHostKeepsOtherHostsRows() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnreachableHost"])

        let row = element("agent.row.\(Self.studio)/w2:p1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "連不上的主機擋住了其他台的列")
        XCTAssertTrue(row.label.contains("Studio Mac"), "非選取中主機的列沒有標示主機名:\(row.label)")
        let error = element("agentList.error.\(Self.lab)", in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 15) || scrollTo(error, in: app), "沒有「主機名：原因」")
        XCTAssertTrue(error.label.hasPrefix("Lab Server: "), error.label)

        let hostButton = app.buttons["toolbar.host"]
        XCTAssertTrue(hostButton.exists)
        XCTAssertEqual(hostButton.label, "Selected Host: Lab Server")
        hostButton.tap()
        let studioItem = app.buttons["Studio Mac"].firstMatch
        XCTAssertTrue(studioItem.waitForExistence(timeout: 5))
        studioItem.tap()

        XCTAssertTrue(hostButton.waitForLabel("Selected Host: Studio Mac", timeout: 5), hostButton.label)
        // 剛才捲到列表下方找錯誤行;Spaces 的卡片較高，最上方的列這時可能在畫面外，捲回頂端。
        app.collectionViews.firstMatch.swipeDown()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.label.contains("Studio Mac"), "選取中主機的列不該標示主機名:\(row.label)")
        XCTAssertTrue(error.exists || scrollTo(error, in: app), "換選取中主機後錯誤行不見了")
    }

    /// 正式 Demo 也演出多主機(#34):沒有已存主機時，Demo 主機的列之外還有示範主機「Studio Mac」的列(標示主機名),
    /// 列表下方「Lab Server: 原因」;主機清單裡沒有示範主機。
    @MainActor
    func testDemoShowsCompanionHosts() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"])

        let studioRow = element("agent.row.DE300000-0000-4000-8000-000000000001/w2:p1", in: app)
        XCTAssertTrue(app.reveal(studioRow, timeout: 20), "沒有示範主機 Studio Mac 的列")
        XCTAssertTrue(studioRow.label.contains("Studio Mac"), studioRow.label)
        let error = element("agentList.error.DE300000-0000-4000-8000-000000000002", in: app)
        XCTAssertTrue(app.reveal(error, timeout: 20), "沒有連不上的示範主機")
        XCTAssertTrue(error.label.hasPrefix("Lab Server: "), error.label)
        XCTAssertEqual(app.buttons["toolbar.host"].label, "Selected Host: Demo")
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
