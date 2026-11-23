import XCTest

/// 聊天列表重做(spec #480、驗收 #489)的 5 個驗收情境:捲動位置、開啟不閃、圖片列高、跟隨底部、跳到最新。
///
/// 斷言都量 accessibility frame(列的位置與高度),不看截圖;跳動會直接表現成位置差。
final class ChatListAcceptanceUITests: XCTestCase {
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let messageIdentifiers = ["conversation.user", "conversation.agent"]

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - 1. 閱讀中 agent 連續新增 20 個工具步驟,可見的第一則訊息不動

    /// 長對話往上捲讀舊訊息;`-demoToolBurst` 在開啟後 10 秒一次接上 20 個工具步驟。
    /// 量到的第一則可見訊息(label 與頂緣)在步驟接上前後必須一致。
    @MainActor
    func testReadingPositionHoldsWhenAgentAdds20ToolSteps() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoToolBurst"])
        let list = app.conversationList
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "對話沒有開啟")
        let jump = app.element("conversation.jumpToLatest")

        for _ in 0..<2 { list.swipeDown() }
        XCTAssertTrue(jump.waitUntilExists(timeout: 5), "往上捲後沒有跳到最新鈕")
        let anchor = firstFullyVisibleMessage(in: app)
        XCTAssertNotNil(anchor, "畫面上找不到可當錨點的訊息")
        guard let anchor else { return }

        // 工具步驟在開啟後 10 秒接上;等過那個時間再多一點,讓列表有時間套用。
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", anchor.identifier, anchor.label)).firstMatch
        var maxDrift: CGFloat = 0
        let deadline = Date().addingTimeInterval(16)
        while Date() < deadline {
            if element.exists { maxDrift = max(maxDrift, abs(element.frame.minY - anchor.minY)) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(element.exists, "閱讀中的錨點訊息消失了")
        XCTAssertLessThanOrEqual(maxDrift, 1, "新增工具步驟時閱讀位置跳動了 \(maxDrift)pt")
        XCTAssertTrue(jump.exists, "往上閱讀時不該被自動拉到底(跳到最新鈕不見了)")

        // 確認 20 個步驟真的接上了(否則上面的比對沒有意義)。
        jump.tap()
        let steps = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "20 steps")).firstMatch
        XCTAssertTrue(steps.waitUntilExists(timeout: 10), "20 個工具步驟沒有接上,情境沒有生效")
    }

    // MARK: - 2. 打開聊天不出現骨架再換列表

    /// 點進聊天後,畫面從第一次看到訊息起就不再出現載入中,而且第一則訊息的位置不再變動。
    @MainActor
    func testOpeningChatNeverShowsSkeletonThenSwapsToList() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()

        let loading = app.element("conversation.loading")
        var sawLoading = false
        var firstMessageSeenAt: Date?
        var positions: [CGFloat] = []
        let message = app.element("conversation.user")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if loading.exists { sawLoading = true }
            if message.exists {
                firstMessageSeenAt = firstMessageSeenAt ?? Date()
                positions.append(message.frame.minY)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotNil(firstMessageSeenAt, "4 秒內沒有出現訊息")
        XCTAssertFalse(sawLoading, "打開聊天時出現了載入中畫面")
        // 位置:轉場動畫結束後(取後半段的樣本)不再變動。
        let settled = Array(positions.suffix(max(positions.count / 2, 1)))
        let spread = (settled.max() ?? 0) - (settled.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 1, "訊息出現後位置還在變動(\(spread)pt),像是骨架換成列表")
    }

    // MARK: - 3. 圖片捲出再捲回,列高不變

    /// AX 字級讓對話超出一個畫面;使用者送出的圖片縮圖與所在訊息捲出畫面再捲回,高度與寬度要一樣。
    @MainActor
    func testImageRowHeightIsStableAfterScrollingAwayAndBack() {
        let app = XCUIApplication.launchUITestingConversation(
            paneID: "w1:p1", flags: ["-demoSentImages"], contentSize: Self.ax5)
        let list = app.conversationList
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "對話沒有開啟")
        let thumbnail = app.element("conversation.sentImage.thumbnail")
        XCTAssertTrue(app.revealInConversation(thumbnail), "縮圖沒有讀回")
        _ = UITestWait.until(timeout: 5) { thumbnail.frame.height > 0 }
        let before = thumbnail.frame.size
        let userRowBefore = app.element("conversation.user").frame.height

        // 往下捲到縮圖整個離開可見範圍。
        var gone = false
        for _ in 0..<8 where !gone {
            list.swipeUp()
            let range = app.visibleConversationRange(of: list)
            gone = !thumbnail.exists || thumbnail.frame.maxY < range.lowerBound || thumbnail.frame.minY > range.upperBound
        }
        XCTAssertTrue(gone, "縮圖一直沒有捲出畫面(測試資料不夠長)")

        XCTAssertTrue(app.revealInConversation(thumbnail), "捲回來後縮圖不見了")
        _ = UITestWait.until(timeout: 5) { thumbnail.frame.height > 0 }
        XCTAssertEqual(thumbnail.frame.size.height, before.height, accuracy: 1, "捲回來後縮圖高度變了")
        XCTAssertEqual(thumbnail.frame.size.width, before.width, accuracy: 1, "捲回來後縮圖寬度變了")
        let userRowAfter = app.element("conversation.user").frame.height
        if app.element("conversation.user").isHittable, userRowBefore > 0 {
            XCTAssertEqual(userRowAfter, userRowBefore, accuracy: 1, "捲回來後訊息列高度變了")
        }
    }

    // MARK: - 4. 停在底部時新訊息跟上

    /// `-demoLargeOutputOnPrompt`:長對話開在底部;送出後回覆與 160 個工具步驟接上,畫面要跟到收尾訊息,不出現跳到最新鈕。
    @MainActor
    func testStaysAtBottomWhenNewMessagesArrive() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoLargeOutputOnPrompt"])
        XCTAssertTrue(app.conversationList.waitUntilExists(timeout: 10), "對話沒有開啟")
        let jump = app.element("conversation.jumpToLatest")
        XCTAssertFalse(jump.waitUntilExists(timeout: 2), "開啟時在底部,不該顯示跳到最新")

        let text = app.element("composer.text")
        text.tap()
        text.typeEnglish("Stay at the bottom")
        app.element("composer.send").tap()

        let summary = app.staticTexts["I read all 160 export logs; every row exported cleanly."]
        XCTAssertTrue(summary.waitUntilExists(timeout: 20), "收尾訊息沒有出現(停在底部時新訊息沒有跟上)")
        let composer = app.element("composer.text")
        XCTAssertLessThanOrEqual(summary.frame.maxY, composer.frame.minY + 1, "收尾訊息被輸入框蓋住")
        XCTAssertFalse(jump.exists, "跟隨底部時不該出現跳到最新")
    }

    // MARK: - 5. 跳到最新後停在最後一則

    /// 往上快滑再點跳到最新:最後一則完整在輸入框上方,且與輸入框之間沒有大片空白(沒有停在內容外)。
    @MainActor
    func testJumpToLatestLandsOnLastMessage() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoLargeOutputOnPrompt"])
        let list = app.conversationList
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "對話沒有開啟")
        let jump = app.element("conversation.jumpToLatest")
        let composer = app.element("composer.text")
        XCTAssertTrue(composer.waitUntilExists(timeout: 5))

        for attempt in 1...3 {
            for _ in 0..<3 { list.swipeDown(velocity: .fast) }
            XCTAssertTrue(jump.waitUntilExists(timeout: 5), "第 \(attempt) 次往上捲後沒有跳到最新")
            jump.tap()
            let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Row 150 looks right.'")).firstMatch
            XCTAssertTrue(last.waitUntilExists(timeout: 5), "第 \(attempt) 次沒有停在最後一則")
            XCTAssertTrue(jump.waitUntilGone(timeout: 5), "第 \(attempt) 次到底後按鈕沒有消失")
            XCTAssertLessThanOrEqual(last.frame.maxY, composer.frame.minY + 1, "第 \(attempt) 次最後一則被輸入框蓋住")
            let gap = composer.frame.minY - last.frame.maxY
            XCTAssertLessThan(gap, 150, "第 \(attempt) 次最後一則與輸入框之間有 \(gap)pt 空白(停在內容外)")
        }
    }

    // MARK: - 輔助

    private struct Anchor {
        let identifier: String
        let label: String
        let minY: CGFloat
    }

    /// 可見範圍內最上面那則完整看得到的訊息(使用者或 agent)。
    @MainActor
    private func firstFullyVisibleMessage(in app: XCUIApplication) -> Anchor? {
        let range = app.visibleConversationRange(of: app.conversationList)
        let candidates = Self.messageIdentifiers.flatMap { identifier in
            app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex.map { (identifier, $0) }
        }
        return candidates
            .filter { _, element in element.exists && !element.label.isEmpty && element.frame.minY >= range.lowerBound && element.frame.maxY <= range.upperBound }
            .sorted { $0.1.frame.minY < $1.1.frame.minY }
            .first
            .map { Anchor(identifier: $0.0, label: $0.1.label, minY: $0.1.frame.minY) }
    }
}
