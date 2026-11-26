import XCTest

/// 多主機合併成同一個 Agent 列表(#39)。UI 測試的已存主機通道都是 Demo 主機;`-seedUnreachableHost` 的主機一律連不上。
final class MultiHostUITests: XCTestCase {
    static let studio = "5EED0000-0000-4000-8000-000000000001"
    static let buildBox = "5EED0000-0000-4000-8000-000000000002"

    override func setUp() {
        continueAfterFailure = false
    }

    /// 一台連不上不影響其他台：其他台的列照常顯示(每列預覽前都是主機名，#244),列表下方「主機名：原因」;
    /// 左上角篩選某一台時只剩那台的列，其他台的錯誤行也收起來，選回所有主機就回來。
    @MainActor
    func testUnreachableHostKeepsOtherHostsRows() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnreachableHost"])

        let row = app.element("spaces.tab.\(Self.studio)/w2:t1")
        XCTAssertTrue(row.waitUntilExists(timeout: 15), "連不上的主機擋住了其他台的列")
        XCTAssertTrue(app.element("spaces.section.\(Self.studio)/w2").label.contains("Studio Mac"), "段落標題沒有標示主機名")
        let error = app.element("agentList.error.\(Self.buildBox)")
        XCTAssertTrue(app.scrollIntoView(error, search: .down, timeout: 15), "沒有「主機名：原因」")
        XCTAssertTrue(error.label.hasPrefix("Build Box: "), error.label)

        app.collectionViews.firstMatch.swipeDown()
        app.filterHosts("Studio Mac")
        XCTAssertTrue(app.buttons["toolbar.currentHost"].firstMatch.waitForLabel("Showing: Studio Mac", timeout: 5))
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        XCTAssertTrue(error.waitUntilGone(timeout: 5), "篩選 Studio Mac 時不該顯示 Build Box 的錯誤")

        app.filterHosts("All Hosts")
        XCTAssertTrue(app.scrollIntoView(error, search: .down, timeout: 5), "選回所有主機後錯誤行沒回來")
    }

    /// 兩台主機有相同的 pane id:各自一列;開非選取中主機的聊天，開出的聊天副標題是狀態。
    @MainActor
    func testSamePaneOnTwoHostsAreSeparateChats() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-selectDemo"])

        // 「需要你」的 w2:p1 在最上面(列表是 lazy,畫面外的列不在 accessibility tree)。
        let demoRow = app.element("spaces.tab.demo/w2:t1")
        let studioRow = app.element("spaces.tab.\(Self.studio)/w2:t1")
        XCTAssertTrue(demoRow.waitUntilExists(timeout: 15))
        XCTAssertTrue(app.scrollIntoView(studioRow, search: .down, timeout: 15), "另一台主機同一個 pane 沒有自己的列")

        studioRow.tap()
        XCTAssertTrue(app.conversationBar.waitUntilExists(timeout: 10))
        // 副標題只有狀態(#618,不含主機名稱):以狀態文字確認開到的是那個「需要你」的聊天。
        XCTAssertTrue(app.conversationSubtitle(containing: "Needs You").waitUntilExists(timeout: 10), "沒有開到非選取中主機的聊天")
    }

}

