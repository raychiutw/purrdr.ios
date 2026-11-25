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

    /// 共用頂列的主機範圍是只有圖示的鈕(#499),在新增聊天左邊、沒有蓋到它。
    @MainActor
    func testHostScopeButtonSitsLeftOfNewChat() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"])
        let filter = app.buttons["toolbar.currentHost"].firstMatch
        XCTAssertTrue(filter.waitUntilExists(timeout: 15))
        XCTAssertGreaterThanOrEqual(filter.frame.height, 36, "主機範圍鈕太矮:\(filter.frame)")
        let newChat = app.buttons["toolbar.newChat"].firstMatch
        XCTAssertLessThan(filter.frame.maxX, newChat.frame.minX, "主機範圍鈕蓋到新增聊天")
    }

    /// 主機篩選(#244):Spaces 檢視只留篩選那台主機的 workspace 段落(#275);篩選選單帶各主機，第一項是所有主機。
    @MainActor
    func testHostFilterLimitsSpaces() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"])
        let demoHeader = app.element("spaces.section.demo/w1")
        let studioHeader = app.element("spaces.section.DE300000-0000-4000-8000-000000000001/w1")
        XCTAssertTrue(demoHeader.waitUntilExists(timeout: 20))
        XCTAssertEqual(app.buttons["toolbar.currentHost"].firstMatch.label, "Showing: All Hosts")

        app.filterHosts("Studio Mac")

        XCTAssertTrue(demoHeader.waitUntilGone(timeout: 5), "篩選 Studio Mac 時不該有 Demo 的段落")
        XCTAssertTrue(app.reveal(studioHeader, timeout: 10), "篩選後沒有 Studio Mac 的段落")
    }

    /// 正式 Demo 也演出多主機(#34):沒有已存主機時，Demo 主機的列之外還有示範主機「Studio Mac」的列,
    /// 列表下方「Build Box: 原因」;主機清單裡沒有示範主機。
    @MainActor
    func testDemoShowsCompanionHosts() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"])

        // 往下捲後頂列收合、不渲染電腦圖示:主機範圍的斷言要在捲動前(列表還在最上面)做。
        let hostFilter = app.buttons["toolbar.currentHost"].firstMatch
        XCTAssertTrue(hostFilter.waitUntilExists(timeout: 20), "沒有電腦圖示")
        XCTAssertEqual(hostFilter.label, "Showing: All Hosts")
        let studioRow = app.element("spaces.tab.DE300000-0000-4000-8000-000000000001/w2:t1")
        XCTAssertTrue(app.reveal(studioRow, timeout: 20), "沒有示範主機 Studio Mac 的列")
        let error = app.element("agentList.error.DE300000-0000-4000-8000-000000000002")
        XCTAssertTrue(app.reveal(error, timeout: 20), "沒有連不上的示範主機")
        XCTAssertTrue(error.label.hasPrefix("Build Box: "), error.label)
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

