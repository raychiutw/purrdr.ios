import XCTest

/// 聊天列表重做(spec #480、驗收 #489)的 5 個驗收情境:捲動位置、開啟不閃、圖片列高、跟隨底部、跳到最新。
///
/// 斷言都量 accessibility frame(列的位置與高度),不看截圖;跳動會直接表現成位置差。
final class ChatListAcceptanceUITests: XCTestCase {
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
    /// 最後一則文字框與列底緣的差(座標四捨五入與文字行距)。
    private static let landingTolerance: CGFloat = 4

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - 1. 閱讀中 agent 連續新增 20 個工具步驟,可見的第一則訊息不動

    /// 長對話往上捲讀舊訊息;`-demoToolBurst` 在開啟後 10 秒一次接上 20 個工具步驟。
    /// 位移由 app 內的除錯量測累計(`conversation.list` 的 value `drift=`):列表停下後以畫面上第一列為基準,
    /// 累計它離可見頂端的最大位移,不靠測試端取樣。
    @MainActor
    func testReadingPositionHoldsWhenAgentAdds20ToolSteps() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoToolBurst"])
        let list = app.conversationList
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "對話沒有開啟")
        let jump = app.element("conversation.jumpToLatest")

        for _ in 0..<2 { list.swipeDown() }
        XCTAssertTrue(jump.waitUntilExists(timeout: 5), "往上捲後沒有跳到最新鈕")
        XCTAssertTrue(
            UITestWait.until(timeout: 5) { Self.debugValue("drift", of: list).map { $0 != "none" } ?? false },
            "列表停下後沒有記下閱讀位置的基準(量測沒有啟用?)")

        // 工具步驟在開啟後 10 秒接上:輪詢列數增加(不靠固定秒數),再等位移量測穩定。
        let rowsBefore = Self.debugValue("rows", of: list).flatMap(Int.init) ?? 0
        XCTAssertTrue(
            UITestWait.until(timeout: 40) { (Self.debugValue("rows", of: list).flatMap(Int.init) ?? 0) > rowsBefore },
            "20 個工具步驟沒有接上(列數一直是 \(rowsBefore)),情境沒有生效")
        var lastDrift = Self.debugValue("drift", of: list)
        var stableReads = 0
        _ = UITestWait.until(timeout: 10) {
            let now = Self.debugValue("drift", of: list)
            stableReads = now == lastDrift ? stableReads + 1 : 0
            lastDrift = now
            return stableReads >= 5
        }
        let driftText = Self.debugValue("drift", of: list)
        let drift = driftText.flatMap(Double.init)
        XCTAssertNotNil(drift, "量測值不是數字:\(driftText ?? "nil")")
        XCTAssertLessThanOrEqual(drift ?? .infinity, 1, "新增工具步驟時閱讀位置跳動了 \(drift ?? -1)pt")
        XCTAssertTrue(jump.exists, "往上閱讀時不該被自動拉到底(跳到最新鈕不見了)")

        // 確認 20 個步驟真的接上了(否則上面的比對沒有意義)。
        jump.tap()
        let steps = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "20 steps")).firstMatch
        XCTAssertTrue(steps.waitUntilExists(timeout: 10), "20 個工具步驟沒有接上,情境沒有生效")
    }

    // MARK: - 2. 打開聊天不出現骨架再換列表

    /// 第一次開啟讓記憶體快取命中;返回後第二次開啟必須同步還原:畫面一出現就有訊息,整段過程沒有載入中,
    /// 而且第一則訊息的位置不再變動。
    @MainActor
    func testOpeningChatNeverShowsSkeletonThenSwapsToList() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element(chatRowID("w1:p1"))
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        let message = app.element("conversation.user")
        XCTAssertTrue(app.element("conversation.header").waitUntilExistsAndSettled(timeout: 15), "沒有開出聊天畫面")
        XCTAssertTrue(message.waitUntilExists(timeout: 10), "第一次開啟後沒有出現訊息")

        // 返回再開第二次(快取命中)。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.reveal(row), "返回後沒有看到 Agent 列表")
        row.tap()

        let loading = app.element("conversation.loading")
        var sawLoading = false
        var positions: [CGFloat] = []
        var hadMessageWhenHeaderAppeared: Bool?
        let header = app.element("conversation.header")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if loading.exists { sawLoading = true }
            if hadMessageWhenHeaderAppeared == nil, header.exists { hadMessageWhenHeaderAppeared = message.exists }
            if message.exists { positions.append(message.frame.minY) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(sawLoading, "第二次打開聊天時出現了載入中畫面")
        XCTAssertEqual(hadMessageWhenHeaderAppeared, true, "第二次打開聊天時,畫面一出現還沒有訊息(沒有同步還原)")
        // 轉場動畫結束後(取後半段的樣本)位置不再變動。
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
        let userRow = app.element("conversation.user")
        let userRowBefore = userRow.frame.height
        XCTAssertGreaterThan(userRowBefore, 0, "量不到訊息列的高度")

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
        // 縮圖在這一列裡,縮圖回來了這一列就在畫面上:直接比高度,不成立就失敗。
        XCTAssertTrue(userRow.exists, "捲回來後找不到訊息列")
        XCTAssertEqual(userRow.frame.height, userRowBefore, accuracy: 1, "捲回來後訊息列高度變了")
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

        var gaps: [CGFloat] = []
        for attempt in 1...3 {
            for _ in 0..<3 { list.swipeDown(velocity: .fast) }
            XCTAssertTrue(jump.waitUntilExists(timeout: 5), "第 \(attempt) 次往上捲後沒有跳到最新")
            jump.tap()
            let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Row 150 looks right.'")).firstMatch
            XCTAssertTrue(last.waitUntilExists(timeout: 5), "第 \(attempt) 次沒有停在最後一則")
            XCTAssertTrue(jump.waitUntilGone(timeout: 5), "第 \(attempt) 次到底後按鈕沒有消失")
            XCTAssertLessThanOrEqual(last.frame.maxY, composer.frame.minY + 1, "第 \(attempt) 次最後一則被輸入框蓋住")
            // 最後一列底緣與列表可見底緣(列表底緣扣掉 app 內實際量到的下方 inset)的距離:不能是負的(被蓋住),
            // 也不能大到像停在內容外(不超過最後一則自己的高度);三次落點要一致,不依賴設計稿的常數。
            let insetBottom = Self.debugValue("insetBottom", of: list).flatMap(Double.init).map { CGFloat($0) }
            XCTAssertNotNil(insetBottom, "讀不到列表實際的下方 inset(量測沒有啟用?)")
            let gap = list.frame.maxY - (insetBottom ?? 0) - last.frame.maxY
            XCTAssertGreaterThanOrEqual(gap, -Self.landingTolerance, "第 \(attempt) 次最後一則被蓋在可見底緣下(差 \(gap)pt)")
            XCTAssertLessThan(gap, last.frame.height, "第 \(attempt) 次最後一則離底緣太遠,像停在內容外(差 \(gap)pt)")
            gaps.append(gap)
        }
        XCTAssertLessThanOrEqual((gaps.max() ?? 0) - (gaps.min() ?? 0), Self.landingTolerance, "三次跳到最新落點不一致:\(gaps)")
    }

    // MARK: - 輔助

    /// 除錯量測放在 `conversation.list` 的 value(`drift=… insetTop=… insetBottom=…`),取其中一個欄位。
    @MainActor
    private static func debugValue(_ key: String, of list: XCUIElement) -> String? {
        guard let value = list.value as? String else { return nil }
        for field in value.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == key { return String(parts[1]) }
        }
        return nil
    }
}
