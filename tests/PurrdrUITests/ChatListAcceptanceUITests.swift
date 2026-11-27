import XCTest

/// 聊天列表重做(spec #480、驗收 #489)的驗收情境:捲動位置、開啟不閃、跳到最新與跟隨底部。
///
/// 斷言都量 accessibility frame(列的位置與高度),不看截圖;跳動會直接表現成位置差。
final class ChatListAcceptanceUITests: XCTestCase {
    /// 大字級讓對話超出一個畫面。不用 AX5:AX5 時「You should know」卡與輸入列佔掉約 625pt,
    /// 可見的訊息區只剩約 130pt,圖片列根本滑不進畫面(測的是列高穩定,不是 AX5 的版面)。
    private static let largeText = "UICTContentSizeCategoryXXXL"
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

    // MARK: - 3. 圖片捲出再捲回,列高不變

    /// 大字級讓對話超出一個畫面;使用者送出的圖片縮圖與所在訊息捲出畫面再捲回,高度與寬度要一樣。
    @MainActor
    func testImageRowHeightIsStableAfterScrollingAwayAndBack() {
        let app = XCUIApplication.launchUITestingConversation(
            paneID: "w1:p1", flags: ["-demoSentImages"], contentSize: Self.largeText)
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

    // MARK: - 4. 跳到最新後停在最後一則;停在底部時新訊息跟上

    /// 「Jump to Latest」只在不在底部時出現:開啟時(在底部)沒有;往上捲出現且不被輸入列蓋住;自己捲回底部消失(#93)。
    /// 往上快滑再點跳到最新:最後一則完整在輸入框上方,且與輸入框之間沒有大片空白(沒有停在內容外)。
    /// 最後在底部送出 prompt:回覆與 160 個工具步驟接上,畫面要跟到收尾訊息,不出現跳到最新鈕。
    @MainActor
    func testJumpToLatestLandsOnLastMessageAndFollowsNewMessages() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoLargeOutputOnPrompt"])
        let list = app.conversationList
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "對話沒有開啟")
        let jump = app.element("conversation.jumpToLatest")
        let composer = app.element("composer.text")
        XCTAssertTrue(composer.waitUntilExists(timeout: 5))
        XCTAssertFalse(jump.waitUntilExists(timeout: 2), "開啟時在底部,不該顯示跳到最新")

        list.swipeDown()
        list.swipeDown()
        XCTAssertTrue(jump.waitUntilExists(timeout: 5), "往上捲後應顯示")
        // 在輸入列(含停止列)上方,不被它蓋住(#476)。
        XCTAssertLessThanOrEqual(jump.frame.maxY, composer.frame.minY, "跳到最新壓在輸入列上")
        for _ in 0..<4 { list.swipeUp() }
        XCTAssertTrue(jump.waitUntilGone(timeout: 5), "自己捲回底部後應隱藏")

        var gaps: [CGFloat] = []
        for attempt in 1...3 {
            for _ in 0..<3 { list.swipeDown(velocity: .fast) }
            XCTAssertTrue(jump.waitUntilExists(timeout: 5), "第 \(attempt) 次往上捲後沒有跳到最新")
            jump.tap()
            let last = app.staticTexts.matching(NSPredicate(format: "identifier == 'conversation.agent' AND label CONTAINS 'Row 150 looks right.'")).firstMatch
            XCTAssertTrue(last.waitUntilExists(timeout: 5), "第 \(attempt) 次沒有停在最後一則")
            XCTAssertTrue(jump.waitUntilGone(timeout: 5), "第 \(attempt) 次到底後按鈕沒有消失")
            XCTAssertLessThanOrEqual(last.frame.maxY, composer.frame.minY + 1, "第 \(attempt) 次最後一則被輸入框蓋住")
            // 最後一列底緣與列表可見底緣(列表底緣扣掉 app 內實際量到的下方 inset)的距離:不能是負的(被蓋住),
            // 也不能大到像停在內容外(不超過最後一則自己的高度);三次落點要一致,不依賴設計稿的常數。
            let insetBottom = Self.debugValue("insetBottom", of: list).flatMap(Double.init).map { CGFloat($0) }
            XCTAssertNotNil(insetBottom, "讀不到列表實際的下方 inset(量測沒有啟用?)")
            // 量最後一則所在的列(cell)而不是文字元素:文字元素的 frame 會比列多出底部約 16pt 的內距
            // (0.52 輸入列改版後列離可見底緣 11.67pt、文字框就多出 4.33pt,超過容許值,畫面上並沒有被蓋住)。
            let lastCell = list.cells.allElementsBoundByIndex.filter { $0.frame.minY <= last.frame.minY + 1 }.max { $0.frame.maxY < $1.frame.maxY }
            XCTAssertNotNil(lastCell, "第 \(attempt) 次找不到最後一則所在的列")
            let gap = list.frame.maxY - (insetBottom ?? 0) - (lastCell?.frame.maxY ?? last.frame.maxY)
            XCTAssertGreaterThanOrEqual(gap, -Self.landingTolerance, "第 \(attempt) 次最後一則被蓋在可見底緣下(差 \(gap)pt)")
            XCTAssertLessThan(gap, last.frame.height, "第 \(attempt) 次最後一則離底緣太遠,像停在內容外(差 \(gap)pt)")
            gaps.append(gap)
        }
        XCTAssertLessThanOrEqual((gaps.max() ?? 0) - (gaps.min() ?? 0), Self.landingTolerance, "三次跳到最新落點不一致:\(gaps)")

        // 人在底部時送出 prompt:新訊息要跟上。
        composer.tap()
        composer.typeEnglish("Stay at the bottom")
        app.element("composer.send").tap()
        // 單段訊息的文字合併在 conversation.agent 元素的 label 裡(「Agent:, …」),所以用 CONTAINS。
        let summary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'I read all 160 export logs; every row exported cleanly.'")).firstMatch
        XCTAssertTrue(summary.waitUntilExists(timeout: 20), "收尾訊息沒有出現(停在底部時新訊息沒有跟上)")
        XCTAssertLessThanOrEqual(summary.frame.maxY, composer.frame.minY + 1, "收尾訊息被輸入框蓋住")
        XCTAssertFalse(jump.exists, "跟隨底部時不該出現跳到最新")
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
