import XCTest

/// Spaces／Agents 兩種檢視與 workspace 群組(#40、#103)。Demo 主機的 `notes`(w3)是 Codex(工作中)+ shell「npm run dev」,
/// 所以在 Spaces 是群組(預設展開);`ledger`(w1)、`weather-app`(w2)只有一個 agent,是聊天列。
final class SpacesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 預設是 Spaces:依主機分組，Demo 主機一組;多 pane 的 workspace 是群組，下方有 agent 列與終端機列;點終端機列開它的 Pane 終端機。
    @MainActor
    func testSpacesShowsGroupAndTerminalRowOpensTerminal() {
        let app = XCUIApplication.launchUITesting()

        let group = element("workspace.group.demo/w3", in: app)
        XCTAssertTrue(group.waitForExistence(timeout: 10), "notes 沒有顯示成 workspace 群組")
        XCTAssertTrue(app.navigationBars["Spaces"].exists, "大標題不是 Spaces")
        let host = element("spaces.host.demo", in: app)
        XCTAssertTrue(host.exists, "沒有 Demo 主機的分組標題")
        XCTAssertTrue(host.label.contains("Demo"), "主機分組標題沒有主機名:\(host.label)")
        XCTAssertLessThan(host.frame.minY, group.frame.minY)
        let agent = element("agent.row.demo/w3:p1", in: app)
        let terminal = element("terminal.row.demo/w3:p2", in: app)
        XCTAssertTrue(agent.exists, "群組下方沒有 agent 列(工作中應預設展開)")
        XCTAssertTrue(terminal.exists, "群組下方沒有終端機列")
        XCTAssertTrue(terminal.label.contains("npm run dev"), "終端機列副標沒有程式名:\(terminal.label)")
        XCTAssertLessThan(group.frame.minY, agent.frame.minY)
        XCTAssertLessThan(agent.frame.minY, terminal.frame.minY)
        XCTAssertTrue(app.reveal(element("agent.row.demo/w1:p1", in: app)), "單一 agent 的 workspace 沒有聊天列")

        app.reveal(terminal)
        terminal.tap()
        let status = element("terminal.status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "點終端機列沒有開 Pane 終端機")
        XCTAssertTrue(status.label.contains("npm run dev"), "終端機標題不是程式名:\(status.label)")
    }

    /// 群組標頭是按鈕，VoiceOver 念出名稱、Agent 數、各狀態數量與展開狀態;點了收合、再點展開。
    @MainActor
    func testGroupHeaderTogglesAndDescribesItself() {
        let app = XCUIApplication.launchUITesting()
        let header = app.buttons["workspace.group.demo/w3"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "群組標頭不是按鈕")
        for part in ["notes", "1 agent", "1 terminal", "Working 1", "Expanded"] {
            XCTAssertTrue(header.label.contains(part), "標頭的 VoiceOver label 沒有「\(part)」:\(header.label)")
        }
        let agent = element("agent.row.demo/w3:p1", in: app)
        XCTAssertTrue(agent.exists)

        header.tap()
        XCTAssertTrue(agent.waitForNonExistence(timeout: 5), "點標頭沒有收合")
        XCTAssertTrue(app.buttons["workspace.group.demo/w3"].label.contains("Collapsed"), "收合後 label 沒有「Collapsed」")

        app.buttons["workspace.group.demo/w3"].tap()
        XCTAssertTrue(agent.waitForExistence(timeout: 5), "再點標頭沒有展開")
    }

    /// 長按群組標頭：選單第一項是版面圖;版面圖的終端機方塊開該 Pane 的終端機(#40 補充)。
    @MainActor
    func testGroupMenuOpensLayoutAndShellBlockOpensTerminal() {
        let app = XCUIApplication.launchUITesting()
        let header = element("workspace.group.demo/w3", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 10))

        header.press(forDuration: 1.2)
        for title in ["Show Layout", "Rename Workspace…", "Close Workspace…"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), "群組選單沒有「\(title)」")
        }
        app.buttons["Show Layout"].tap()
        let shellBlock = app.buttons["layout.block.w3:p2"]
        XCTAssertTrue(shellBlock.waitForExistence(timeout: 5), "選單沒有開版面圖")
        shellBlock.tap()

        let status = element("terminal.status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "點終端機方塊沒有開 Pane 終端機")
        XCTAssertTrue(status.label.contains("npm run dev"), "終端機標題不是程式名:\(status.label)")
    }

    /// 列表在最上面時是大標題(導覽列下方、大字);它是按鈕(VoiceOver 唸「Spaces,按鈕」),點了出檢視選單，
    /// 選 Agents 後每個 agent 一列，沒有群組與終端機列，大標題變成 Agents(#66)。
    @MainActor
    func testLargeTitleSwitchesToAgents() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(element("workspace.group.demo/w3", in: app).waitForExistence(timeout: 10))

        let title = app.buttons["agentList.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "大標題不是按鈕(VoiceOver 與 UI 測試找不到)")
        XCTAssertEqual(title.label, "Spaces")
        let bar = app.navigationBars.firstMatch.frame
        XCTAssertGreaterThanOrEqual(title.frame.minY, bar.maxY - 1, "標題不在導覽列下方(不是大標題):\(title.frame) 導覽列 \(bar)")
        XCTAssertGreaterThanOrEqual(title.frame.height, 34, "標題字不夠大:\(title.frame)")
        XCTAssertFalse(app.navigationBars.buttons["Spaces"].exists, "大標題顯示時導覽列不該再有小標題")

        title.tap()
        let agents = app.buttons["Agents"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5), "點大標題沒有出現檢視選單")
        agents.tap()

        XCTAssertTrue(element("workspace.group.demo/w3", in: app).waitForNonExistence(timeout: 5), "Agents 檢視不該有群組")
        XCTAssertTrue(element("agent.row.demo/w3:p1", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("terminal.row.demo/w3:p2", in: app).exists, "Agents 檢視不該有終端機列")
        XCTAssertTrue(app.buttons["agentList.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["agentList.title"].label, "Agents", "大標題沒有變成 Agents")
    }

    /// 選的檢視記在這支裝置：重新啟動後還是 Agents(#66)。`-rememberListMode` 讓 UI 測試也存進 UserDefaults
    /// (平常 UI 測試只放記憶體);`-resetListMode` 先清掉上一次留下的值。
    @MainActor
    func testViewChoiceSurvivesRelaunch() {
        let app = XCUIApplication.launchUITesting(flags: ["-rememberListMode", "-resetListMode"])
        let title = app.buttons["agentList.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Spaces", "清掉之後應該從 Spaces 開始")
        title.tap()
        app.buttons["Agents"].firstMatch.tap()
        XCTAssertTrue(element("workspace.group.demo/w3", in: app).waitForNonExistence(timeout: 5))
        app.terminate()

        let again = XCUIApplication.launchUITesting(flags: ["-rememberListMode"])
        let restored = again.buttons["agentList.title"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(restored.label, "Agents", "重新啟動後沒有記住 Agents")
        XCTAssertTrue(element("agent.row.demo/w3:p1", in: again).waitForExistence(timeout: 10))
        XCTAssertFalse(element("workspace.group.demo/w3", in: again).exists)
        again.terminate()

        // 清掉，不影響之後的測試。
        XCUIApplication.launchUITesting(flags: ["-rememberListMode", "-resetListMode"]).terminate()
    }

    /// AX5 字級：大標題換行而不截斷(accessibility audit 的 textClipped 不能落在標題上)，整個在視窗內(#66)。
    @MainActor
    func testLargeTitleNotClippedAtAX5() throws {
        let app = XCUIApplication.launchUITesting(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let title = app.buttons["agentList.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "AX5 時沒有大標題按鈕")
        XCTAssertEqual(title.label, "Spaces")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(title.frame), "大標題超出視窗:\(title.frame) 視窗 \(window)")
        // 被截斷的可能是標題按鈕本身，也可能是它裡面的文字(沒有 identifier):看位置有沒有落在標題範圍內。
        let frame = title.frame
        var clipped: [String] = []
        try app.performAccessibilityAudit(for: .textClipped) { issue in
            guard let element = issue.element, element.frame.intersects(frame) else { return true }
            clipped.append(issue.compactDescription)
            return true
        }
        XCTAssertEqual(clipped, [], "AX5 大標題被截斷")
    }

    /// 切換檢視時捲回最上面(#40):換了檢視就是另一份清單，不留在原本捲到的位置。
    /// 捲下去後大標題收合成導覽列的小標題，小標題一樣能點出檢視選單(系統的 title menu,#66)。
    @MainActor
    func testSwitchingViewScrollsToTop() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"])
        XCTAssertTrue(element("workspace.group.demo/w3", in: app).waitForExistence(timeout: 10))
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 { list.swipeUp() }
        let top = element("agentList.section.needsYou", in: app)
        XCTAssertFalse(top.exists && top.isHittable, "沒有捲下去，測不出來")

        app.navigationBars["Spaces"].buttons["Spaces"].firstMatch.tap()
        let agents = app.buttons["Agents"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.tap()

        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(top.waitForExistence(timeout: 5) && top.isHittable, "切到 Agents 後沒有回到最上面")
        XCTAssertTrue(app.buttons["agentList.title"].waitForExistence(timeout: 5), "回到最上面後沒有大標題")
        XCTAssertFalse(app.navigationBars.buttons["Agents"].exists, "回到最上面後導覽列不該再有小標題")
    }

    /// 按壓回饋(#234):按住一下再放開(短於長按選單)，群組標頭仍收合、大標題仍出檢視選單;按住時的畫面附在結果裡。
    @MainActor
    func testHeldGroupHeaderAndLargeTitleStillAct() {
        let app = XCUIApplication.launchUITesting()
        let header = app.buttons["workspace.group.demo/w3"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "群組標頭不是按鈕")
        let agent = element("agent.row.demo/w3:p1", in: app)
        XCTAssertTrue(agent.exists)

        header.press(forDuration: 0.3)
        XCTAssertTrue(agent.waitForNonExistence(timeout: 5), "按住後放開群組標頭沒有收合")

        let title = app.buttons["agentList.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "大標題不是按鈕")
        title.press(forDuration: 0.3)
        XCTAssertTrue(app.buttons["Agents"].firstMatch.waitForExistence(timeout: 5), "按住後放開大標題沒有出現檢視選單")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "press-feedback-spaces"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
