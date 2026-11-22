import XCTest

/// 無障礙總稽核(#35)找到的問題，各自的回歸測試。
final class AccessibilityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Agents 檢視的 Agent 列(notes 的 Codex):預設字級時狀態與時間在右側，列的高度跟三行文字差不多，
    /// 不會在中間留一大片空白、把「Now」擠到列底(#34 截圖 01-agent-list)。
    /// 副標較長的列(weather-app 的「需要你」)也一樣：預設字級不改成上下堆疊(堆疊只在 AX 字級)。
    @MainActor
    func testAgentRowsKeepStatusBesideTextAtDefaultSize() {
        continueAfterFailure = true
        let app = XCUIApplication.launchUITesting()
        let codex = app.element("agent.row.demo/w3:p1")
        XCTAssertTrue(app.reveal(codex), "列表沒有 Codex 列")
        // iPhone 17 預設字級：標題折成兩行 + 副標 + 預覽約 112pt;上下堆疊(狀態、時間各佔一行)約 132pt;
        // 狀態標題被擠成一字一行時約 188pt。
        XCTAssertLessThan(codex.frame.height, 125, "Codex 列太高:\(codex.frame)")
        let needsYou = app.element("agent.row.demo/w2:p1")
        XCTAssertTrue(app.reveal(needsYou))
        XCTAssertLessThan(needsYou.frame.height, 125, "「需要你」列太高(上下堆疊了):\(needsYou.frame)")
    }

    /// VoiceOver:每則訊息是一個元素(作者 + 內容 + 時間一次念完),不是每段文字各自一個(HIG 20.5)。
    /// 程式碼區塊的複製鈕與連結仍可操作(見 `ConversationUITests`)。
    @MainActor
    func testEachMessageIsOneElement() {
        continueAfterFailure = true
        let app = XCUIApplication.launchUITesting()
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row))
        row.tap()

        let user = app.element("conversation.user")
        XCTAssertTrue(user.waitUntilExists(timeout: 10))
        // 合成一個元素：在 accessibility tree 是一個 StaticText,label 依序是作者、內容、時間。
        // (XCUITest 仍列得出 SwiftUI 給自動化用的子節點，所以不數子元素。)
        XCTAssertEqual(user.elementType, .staticText, "使用者泡泡不是單一元素:\(user.debugDescription)")
        XCTAssertTrue(user.label.hasPrefix("Your message"), user.label)
        XCTAssertTrue(user.label.contains("Tidy up the CSV export"), user.label)
        XCTAssertTrue(user.label.hasSuffix("PM") || user.label.hasSuffix("AM"), "沒有念時間:\(user.label)")

        // 純文字的那則(有程式碼區塊或表格的訊息是容器，程式碼與表格各自可操作)。
        let agent = app.descendants(matching: .any).matching(identifier: "conversation.agent")
            .matching(NSPredicate(format: "label CONTAINS %@", "start by running the export tests")).firstMatch
        XCTAssertTrue(agent.waitUntilExists(timeout: 10), "沒有那則 agent 訊息")
        XCTAssertEqual(agent.elementType, .staticText, "agent 訊息不是單一元素:\(agent.debugDescription)")
        XCTAssertTrue(agent.label.hasPrefix("Agent"), agent.label)
        XCTAssertGreaterThan(agent.label.count, 20, "agent 訊息沒有念出內容:\(agent.label)")
    }
}
