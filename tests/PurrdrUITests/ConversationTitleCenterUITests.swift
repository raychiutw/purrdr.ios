import XCTest

/// #714:聊天標題膠囊(`conversation.title`)在各種副標題狀態、推入轉場與旋轉後，水平中心都要貼著畫面中線(誤差 2pt 內)。
/// 量 frame 不點座標;逐次取樣，推入過程中與穩定後都檢查。
final class ConversationTitleCenterUITests: XCTestCase {
    private static let tolerance: CGFloat = 2

    override func setUp() {
        continueAfterFailure = false
        // 前一個測試失敗時可能停在橫向:每個測試都從直向開始。
        XCUIDevice.shared.orientation = .portrait
    }

    /// 膠囊中心與視窗中線的差(pt);膠囊不存在回 nil。
    @MainActor
    private func centerOffset(_ app: XCUIApplication) -> CGFloat? {
        let title = app.descendants(matching: .any)["conversation.title"].firstMatch
        guard title.existsWithoutIdle else { return nil }
        return title.frame.midX - app.windows.firstMatch.frame.midX
    }

    /// 等膠囊出現,持續取樣約 `duration` 秒,回傳最大偏差(含推入轉場中)。
    @MainActor
    private func maxOffset(_ app: XCUIApplication, duration: TimeInterval, label: String) -> CGFloat {
        XCTAssertTrue(UITestWait.until(timeout: 15) { centerOffset(app) != nil }, "\(label):沒有標題膠囊")
        var worst: CGFloat = 0
        let end = Date().addingTimeInterval(duration)
        repeat {
            if let offset = centerOffset(app), abs(offset) > abs(worst) { worst = offset }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < end
        print("[TITLE-CENTER] \(label): maxOffset=\(worst) frame=\(app.descendants(matching: .any)["conversation.title"].firstMatch.frame) window=\(app.windows.firstMatch.frame)")
        return worst
    }

    /// 完成、需要你、工作中三種副標題:點進聊天(含轉場)後中心都在中線。
    @MainActor
    func testTitleCapsuleCenteredForEachStatus() {
        let app = XCUIApplication.launchUITesting()
        for (paneID, status) in [("w1:p1", "Done"), ("w2:p1", "Needs You"), ("w3:p1", "Working")] {
            let row = app.element(chatRowID(paneID))
            XCTAssertTrue(app.reveal(row), "沒有看到 \(paneID)")
            row.tap()
            let block = app.buttons["layout.block.\(paneID)"]
            if block.waitUntilExists(timeout: 2) { block.tap() }
            let worst = maxOffset(app, duration: 2, label: status)
            XCTAssertLessThanOrEqual(abs(worst), Self.tolerance, "\(status):標題膠囊偏離中線 \(worst)pt")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.element(chatRowID(paneID)).waitUntilExists(timeout: 10), "沒有回到列表")
        }
    }

    /// 斷網後副標題變成「Reconnecting…」,膠囊寬度改變後仍置中。
    @MainActor
    func testTitleCapsuleCenteredWhenReconnecting() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: [.demoGoesOffline])
        let before = maxOffset(app, duration: 1, label: "before-offline")
        XCTAssertLessThanOrEqual(abs(before), Self.tolerance, "斷網前偏離 \(before)pt")
        let reconnecting = app.conversationSubtitle(containing: "Reconnecting")
        XCTAssertTrue(reconnecting.waitUntilExists(timeout: 60), "沒有重新連線中")
        let after = maxOffset(app, duration: 1, label: "reconnecting")
        XCTAssertLessThanOrEqual(abs(after), Self.tolerance, "重新連線中偏離 \(after)pt")
    }

    /// 字級放大時膠囊變寬,仍須置中(一個字級一個測試:一個測試啟動多次 app 會超過 3 分鐘的時限)。
    @MainActor
    private func assertCentered(contentSize: String) {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w2:p1", contentSize: contentSize)
        let worst = maxOffset(app, duration: 1, label: contentSize)
        XCTAssertLessThanOrEqual(abs(worst), Self.tolerance, "\(contentSize):標題膠囊偏離中線 \(worst)pt")
    }

    @MainActor
    func testTitleCapsuleCenteredAtXXLText() { assertCentered(contentSize: "UICTContentSizeCategoryXXL") }

    @MainActor
    func testTitleCapsuleCenteredAtAccessibilityLText() { assertCentered(contentSize: "UICTContentSizeCategoryAccessibilityL") }

    /// 開著動畫:推入轉場一結束(返回鈕與標題都停下)到副標題切換(工作中 → 需要你)為止,中心都要在中線。
    /// 轉場進行中的 frame 是動畫中間值,不在斷言內(只印出);穩定後與切換時才算。
    @MainActor
    func testTitleCapsuleCenteredWithAnimationsAndStatusChange() {
        let app = XCUIApplication.launchUITesting(flags: [.uiTestingAnimations, .demoNeedsYouLater])
        let row = app.element(chatRowID("w3:p1"))
        XCTAssertTrue(app.reveal(row), "沒有看到 w3:p1")
        row.tap()
        let block = app.buttons["layout.block.w3:p1"]
        if block.waitUntilExists(timeout: 2) { block.tap() }
        var worst: CGFloat = 0
        var transitionWorst: CGFloat = 0
        let started = Date()
        let end = started.addingTimeInterval(8)
        repeat {
            if let offset = centerOffset(app) {
                if Date().timeIntervalSince(started) < 1 {
                    if abs(offset) > abs(transitionWorst) { transitionWorst = offset }
                } else if abs(offset) > abs(worst) {
                    worst = offset
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        } while Date() < end
        print("[TITLE-CENTER] animated: transition=\(transitionWorst) afterSettle=\(worst)")
        XCTAssertTrue(app.conversationSubtitle(containing: "Needs You").exists, "副標題沒有切到需要你")
        XCTAssertLessThanOrEqual(abs(worst), Self.tolerance, "動畫開啟、狀態切換後偏離 \(worst)pt")
    }

    /// 很長的 Tab 名稱:膠囊被截斷在可用寬度內,不被推到一邊。
    @MainActor
    func testTitleCapsuleCenteredWithLongTabName() {
        let app = XCUIApplication.launchUITesting()
        let tab = app.element(chatRowID("w2:p1"))
        XCTAssertTrue(app.reveal(tab), "沒有看到 w2:p1")
        tab.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["menu.renameTab"].waitUntilExists(timeout: 5), "Tab 列沒有跳出選單")
        app.buttons["menu.renameTab"].tap()
        let alert = app.alerts["Rename Tab"]
        XCTAssertTrue(alert.waitUntilExists(timeout: 5))
        alert.textFields.firstMatch.typeEnglish(XCUIKeyboardKey.delete.rawValue + "Refactor the whole billing export pipeline overnight")
        alert.buttons["Rename"].tap()
        XCTAssertTrue(alert.waitUntilGone(timeout: 5))
        XCTAssertTrue(app.reveal(tab), "改名後沒有看到 w2:p1")
        tab.tap()
        let block = app.buttons["layout.block.w2:p1"]
        if block.waitUntilExists(timeout: 2) { block.tap() }
        let worst = maxOffset(app, duration: 1, label: "long-tab-name")
        XCTAssertLessThanOrEqual(abs(worst), Self.tolerance, "長名稱:標題膠囊偏離中線 \(worst)pt")
    }

    /// 旋轉後仍置中。
    @MainActor
    func testTitleCapsuleCenteredAfterRotation() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w2:p1")
        let window = app.windows.firstMatch
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(UITestWait.until(timeout: 10) { window.frame.width > window.frame.height }, "沒有轉成橫向")
        app.descendants(matching: .any)["conversation.title"].firstMatch.waitUntilFrameStops()
        let landscape = maxOffset(app, duration: 2, label: "landscape")
        XCTAssertLessThanOrEqual(abs(landscape), Self.tolerance, "橫向偏離 \(landscape)pt")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(UITestWait.until(timeout: 10) { window.frame.width < window.frame.height }, "沒有轉回直向")
        app.descendants(matching: .any)["conversation.title"].firstMatch.waitUntilFrameStops()
        let portrait = maxOffset(app, duration: 2, label: "portrait")
        XCTAssertLessThanOrEqual(abs(portrait), Self.tolerance, "轉回直向偏離 \(portrait)pt")
    }
}
