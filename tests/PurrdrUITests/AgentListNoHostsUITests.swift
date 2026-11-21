import XCTest

/// 沒有主機時的 Agent 列表空狀態(#332):說明加主要按鈕「Add Host」開新增主機引導,另有「Try the Demo」。
final class AgentListNoHostsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testNoHostsShowsAddHostButtonThatOpensGuide() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingNoHosts"])

        XCTAssertTrue(app.descendants(matching: .any)["agentList.noHosts"].waitForExistence(timeout: 10), "沒有看到沒有主機的空狀態")
        XCTAssertFalse(app.descendants(matching: .any)["agent.row.demo/w1:p1"].exists, "沒有主機時不該直接列出 Demo 的 Agent")
        let add = app.buttons["agentList.addHost"]
        XCTAssertTrue(add.exists)
        add.tap()
        XCTAssertTrue(app.buttons["guide.option.ssh"].waitForExistence(timeout: 5), "沒有開出新增主機引導")
    }

    @MainActor
    func testTryDemoShowsDemoAgents() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingNoHosts"])

        let demo = app.buttons["agentList.tryDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        XCTAssertTrue(app.reveal(app.descendants(matching: .any)["agent.row.demo/w1:p1"].firstMatch), "試用 Demo 後沒有看到 Demo 的 Agent")
        XCTAssertFalse(app.descendants(matching: .any)["agentList.noHosts"].exists)
    }
}
