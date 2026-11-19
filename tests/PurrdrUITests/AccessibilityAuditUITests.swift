import XCTest

/// 無障礙總稽核(#35):以 Demo 主機逐一打開主要畫面，跑 Xcode 的 accessibility audit(`performAccessibilityAudit`)。
///
/// 預設字級跑全部稽核類型;AX5(`AccessibilityXXXL`)再跑一次，看 Dynamic Type 與文字截斷。
/// 確定是系統元件造成或屬於誤報的問題，在 `AccessibilityAuditExclusions` 逐筆寫明理由後排除;其餘一律算失敗。
/// iPad 的稽核在 `IPadLayoutUITests`。
final class AccessibilityAuditUITests: XCTestCase {
    static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 等這些元素的位置連續兩次取樣都不變(動畫、捲動停下)。
    @MainActor
    private func waitForSettledLayout(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = elements.map(\.frame)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let current = elements.map(\.frame)
            if current == previous { return true }
            previous = current
        }
        return false
    }

    // MARK: - Agent 列表

    @MainActor
    func testAgentListSpaces() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            XCTAssertTrue(app.reveal(element("workspace.group.demo/w3", in: app)))
            try audit(app, "Agent 列表(Spaces)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testAgentListAgents() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            XCTAssertTrue(element("agent.row.demo/w2:p1", in: app).waitForExistence(timeout: 15))
            app.switchListMode(to: "Agents")
            // AX5 時導覽列標題由系統縮成 Large Content Viewer 樣式，不以標題判斷：群組消失就是 Agents 檢視。
            XCTAssertTrue(element("workspace.group.demo/w3", in: app).waitForNonExistence(timeout: 5), "沒有切到 Agents 檢視")
            XCTAssertTrue(element("agent.row.demo/w2:p1", in: app).waitForExistence(timeout: 10))
            try audit(app, "Agent 列表(Agents)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testNotesListAndLayout() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            let summary = app.buttons["youShouldKnow.summary"]
            XCTAssertTrue(summary.waitForExistence(timeout: 15))
            summary.tap()
            XCTAssertTrue(element("youShouldKnow.go.demo/w1:p1", in: app).waitForExistence(timeout: 5))
            try audit(app, "You should know 清單", contentSize: size)
            app.terminate()

            let again = XCUIApplication.launchUITesting(contentSize: size)
            let group = element("workspace.group.demo/w3", in: again)
            XCTAssertTrue(again.reveal(group))
            group.press(forDuration: 1.2)
            again.buttons["Show Layout"].tap()
            XCTAssertTrue(again.buttons["layout.block.w3:p2"].waitForExistence(timeout: 5))
            try audit(again, "版面圖", contentSize: size)
            again.terminate()
        }
    }

    // MARK: - 對話

    @MainActor
    private func openChat(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        if paneID == "w1:p1" {
            // AX5 時 ledger 在閒置組很下面，捲不到：從註記清單的「Go to Chat」進去。
            let summary = app.buttons["youShouldKnow.summary"]
            XCTAssertTrue(summary.waitForExistence(timeout: 15))
            summary.tap()
            element("youShouldKnow.go.demo/w1:p1", in: app).tap()
            let text = element("composer.text", in: app)
            XCTAssertTrue(text.waitForExistence(timeout: 10), "沒有輸入框")
            return text
        }
        let row = element("agent.row.demo/\(paneID)", in: app)
        XCTAssertTrue(app.reveal(row), "列表上沒有 \(paneID)")
        row.tap()
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10), "沒有輸入框")
        return text
    }

    @MainActor
    func testConversationNeedsYou() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w2:p1", in: app)
            XCTAssertTrue(element("prompt.card", in: app).waitForExistence(timeout: 15))
            try audit(app, "對話(需要你、subagent)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testConversationWithNoteCard() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w1:p1", in: app)
            XCTAssertTrue(element("youShouldKnow.note", in: app).waitForExistence(timeout: 15))
            try audit(app, "對話(You should know 卡片)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testConversationWorking() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w3:p1", in: app)
            let stop = element("stopBar.stop", in: app)
            XCTAssertTrue(stop.waitForExistence(timeout: 15))
            // 停止列出現時輸入卡片長高、對話跟著捲動：等版面停下再稽核。
            XCTAssertTrue(waitForSettledLayout([stop, element("conversation.working", in: app)], timeout: 5), "版面沒有停下")
            try audit(app, "對話(工作中)", contentSize: size)
            // 工作中指示在輸入卡片正上方的漸層帶：不論 audit 有沒有回報，都以截圖量實際對比(#220)。
            let workingLabel = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Writing'")).firstMatch
            XCTAssertTrue(workingLabel.exists, "沒有工作中指示")
            let contrast = measuredTextContrast(workingLabel) ?? 0
            XCTAssertGreaterThanOrEqual(contrast, 4.5, "工作中指示的實際對比只有 \(contrast)")

            // 強制結束的確認對話框(#220)。
            stop.press(forDuration: 1.0)
            let menuItem = app.buttons["Force Quit…"]
            XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "長按沒有強制結束的選項")
            menuItem.tap()
            let confirm = app.buttons["stopBar.forceQuit.confirm"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "沒有強制結束的確認對話框")
            XCTAssertTrue(waitForSettledLayout([confirm], timeout: 5), "確認對話框沒有停下")
            try audit(app, "強制結束確認", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testSlashMenuAndPanels() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            let text = openChat("w1:p1", in: app)
            text.tap()
            text.typeEnglish("/")
            XCTAssertTrue(element("slash.row.demo-kit:changelog", in: app).waitForExistence(timeout: 10))
            // 選單出現時輸入列上方的元素還在收合、玻璃在淡入：等版面停下再稽核(#249:量到的是動畫中被蓋住一半的加入圖片鈕)。
            let menu = element("slash.menu", in: app)
            XCTAssertTrue(waitForSettledLayout([menu, element("composer.addImage", in: app), text], timeout: 5), "版面沒有停下")
            try audit(app, "slash 選單", contentSize: size)
            text.typeEnglish("model")
            element("slash.row.model", in: app).tap()
            element("composer.send", in: app).tap()
            XCTAssertTrue(element("panel.card", in: app).waitForExistence(timeout: 10))
            element("composer.hideKeyboard", in: app).tap()
            try audit(app, "/model 面板卡片", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testShellCommand() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            let text = openChat("w1:p1", in: app)
            text.tap()
            text.typeEnglish("!git status")
            element("composer.send", in: app).tap()
            XCTAssertTrue(element("conversation.shell", in: app).waitForExistence(timeout: 15))
            element("composer.hideKeyboard", in: app).tap()
            try audit(app, "! 指令", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testTerminal() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w1:p1", in: app)
            let open = app.buttons["terminal.open"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.tap()
            XCTAssertTrue(element("terminal.screen", in: app).waitForExistence(timeout: 10))
            try audit(app, "終端機", contentSize: size)
            app.terminate()
        }
    }

    // MARK: - Sheet

    @MainActor
    private func openMenu(_ item: String, in app: XCUIApplication) {
        tapToolbarItem("toolbar.more", overflowLabel: "More", in: app)
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    /// 點列表工具列右側的項目。AX 字級時系統把右側的「⋯」與帳號鈕收進工具列的溢出選單(More):
    /// 選單項目沒有 identifier,以 VoiceOver 也會念的名稱找(名稱不對就是 a11y 問題)。
    @MainActor
    private func tapToolbarItem(_ identifier: String, overflowLabel: String, in app: XCUIApplication) {
        let item = app.buttons[identifier].firstMatch
        let overflow = app.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10) || overflow.exists, "工具列沒有 \(identifier) 也沒有溢出選單")
        if item.exists {
            item.tap()
            return
        }
        overflow.tap()
        // 溢出鈕自己的名稱也是「More」。
        let overflowItem = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", overflowLabel, "OverflowBarButtonItem")).firstMatch
        XCTAssertTrue(overflowItem.waitForExistence(timeout: 5), "溢出選單裡沒有「\(overflowLabel)」")
        overflowItem.tap()
    }

    @MainActor
    func testHostsEditorAndShare() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(flags: ["-seedHost"], contentSize: size)
            openMenu("menu.hosts", in: app)
            let row = app.buttons["hosts.row.5EED0000-0000-4000-8000-000000000001"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            try audit(app, "主機清單", contentSize: size)

            row.press(forDuration: 1)
            app.buttons["Share…"].firstMatch.tap()
            XCTAssertTrue(element("hostShare.qr", in: app).waitForExistence(timeout: 5))
            try audit(app, "分享主機", contentSize: size)
            // 返回鈕:AX5 時系統只留箭頭，不以標題找。
            app.navigationBars["Share Host"].buttons.firstMatch.tap()

            XCTAssertTrue(app.buttons["hosts.add"].waitForExistence(timeout: 5))
            app.buttons["hosts.add"].tap()
            // AX5 時「Test Connection」在畫面外(Form 是 lazy),以第一個欄位判斷表單已開。
            XCTAssertTrue(app.textFields["hostEditor.name"].waitForExistence(timeout: 5))
            try audit(app, "新增主機", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testSettings() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.uiTesting(contentSize: size)
            app.launch()
            app.open(URL(string: "purrdr://settings")!)
            XCTAssertTrue(element("sheet.settings", in: app).waitForExistence(timeout: 10))
            try audit(app, "設定", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testPaywall() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            app.openPlusPaywall()
            XCTAssertTrue(element("plus.plan.com.raychiu.purrdr.plus.monthly", in: app).waitForExistence(timeout: 15))
            try audit(app, "付費牆", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testSignIn() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            tapToolbarItem("toolbar.account", overflowLabel: "Account", in: app)
            XCTAssertTrue(element("account.plusSetup", in: app).waitForExistence(timeout: 10))
            try audit(app, "帳號", contentSize: size)
            app.buttons["account.plusSetup.action"].tap()
            XCTAssertTrue(app.buttons["member.signIn.apple"].waitForExistence(timeout: 10))
            try audit(app, "登入", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testWelcome() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"], contentSize: size)
            XCTAssertTrue(element("sheet.welcome", in: app).waitForExistence(timeout: 10))
            try audit(app, "歡迎頁", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testNewChat() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            openMenu("menu.newChat", in: app)
            XCTAssertTrue(element("sheet.newChat", in: app).waitForExistence(timeout: 10))
            try audit(app, "新增對話", contentSize: size)
            app.terminate()
        }
    }
}
