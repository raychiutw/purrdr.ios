import XCTest

// UI 測試導航 module(#369):等待、捲動、打開畫面、收鍵盤只有這一份實作。
//
// 為什麼不用 `waitForExistence`:它在第一次檢查前固定等約 1.04 秒(依 2026-11-22 的 log 量測，
// 1,550 次等待裡 95% 第一次檢查就成立，全部白等)。這裡一律先立刻檢查、再以短間隔輪詢。
// 測試檔不要自己寫 `waitForExistence`、`XCTWaiter`、`scrollTo`、`tapWhenReady`、`openAccount`、
// `open(paneID:)`;缺什麼加在這裡。

enum UITestWait {
    /// 輪詢間隔。檢查本身(取 accessibility 快照)就要幾十毫秒，這個值只是不讓它空轉。
    static let pollInterval: TimeInterval = 0.1

    /// 先立刻檢查一次，不成立才每隔 `pollInterval` 再查，到 `timeout` 為止。回傳條件最後是否成立。
    @MainActor
    static func until(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        if condition() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // 用 run loop 睡，讓主執行緒仍處理 XCTest 的事件。
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
            if condition() { return true }
        }
        return condition()
    }
}

extension XCUIElement {
    /// 等元素出現(取代 `waitForExistence`:不固定多等 1 秒)。
    @MainActor
    @discardableResult
    func waitUntilExists(timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout: timeout) { exists }
    }

    /// 等元素消失。
    @MainActor
    @discardableResult
    func waitUntilGone(timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout: timeout) { !exists }
    }

    /// 等元素出現且可點。
    @MainActor
    @discardableResult
    func waitUntilHittable(timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout: timeout) { exists && isHittable }
    }

    /// 等元素出現(換頁動畫)再點。
    @MainActor
    func tapWhenReady(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntilExists(timeout: timeout), "\(identifier) 沒有出現", file: file, line: line)
        tap()
    }

    /// 等 accessibility label 變成指定值。
    @MainActor
    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout: timeout) { exists && self.label == label }
    }

    /// 等 accessibility value 變成指定字串。
    @MainActor
    func waitForValue(_ value: String, timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout: timeout) { exists && (self.value as? String) == value }
    }

    /// 等 accessibility label 包含指定文字。
    @MainActor
    func waitForLabel(containing text: String, timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout: timeout) { exists && label.contains(text) }
    }

    /// 等任意條件(給 `value` 以外的屬性，例如 `hasKeyboardFocus`、`isSelected`)。
    @MainActor
    func wait(timeout: TimeInterval, until condition: (XCUIElement) -> Bool) -> Bool {
        UITestWait.until(timeout: timeout) { condition(self) }
    }

    /// 等 NSPredicate(以元素為對象，例如 `"isEnabled == true"`)成立。
    @MainActor
    func wait(for predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout: timeout) { predicate.evaluate(with: self) }
    }

    /// 斷言 value 在期限內變成指定字串。
    @MainActor
    func expectValue(_ value: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForValue(value, timeout: timeout),
                      "\(identifier) 不是「\(value)」:\(String(describing: self.value))", file: file, line: line)
    }

    /// 斷言 value(字串)在期限內包含指定文字(終端機畫面等)。
    @MainActor
    func expectValue(containing text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let found = UITestWait.until(timeout: timeout) { exists && (value as? String)?.contains(text) == true }
        XCTAssertTrue(found, "畫面沒有出現「\(text)」:\(value ?? "nil")", file: file, line: line)
    }

    /// 斷言 label 在期限內包含指定文字。
    @MainActor
    func expectLabel(containing text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForLabel(containing: text, timeout: timeout), "\(identifier) 沒有「\(text)」:\(label)", file: file, line: line)
    }
}

extension XCUIApplication {
    /// 以 accessibility identifier 找任何種類的元素(各類別不再各寫一份 `element(_:in:)`)。
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }

    /// 識別碼相同、label 以 `prefix` 開頭的元素(卡片標題、縮圖等同一種元素有好幾個時)。
    func element(_ identifier: String, labelPrefix prefix: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", identifier, prefix)).firstMatch
    }

    /// 捲動搜尋的方向：`down` 內容往上捲(`swipeUp`,往下找)、`up` 往上找(`swipeDown`),`both` 先往下找再往上找。
    enum ScrollSearch {
        case down
        case up
        case both
    }

    /// 捲到元素出現、可點，且不在鍵盤底下。列表是 lazy,畫面外的列不在 accessibility tree,所以邊捲邊找。
    ///
    /// 先立刻檢查：已經看得到就不捲。`container` 是要滑動的捲動區(預設整個 app;帳號頁等 sheet 傳它的元素)。
    /// 捲完還沒看到、`timeout` 又大於 0 時，再輪詢到期限(內容是非同步才出現的，例如連線失敗後才冒出的錯誤行)。
    /// 回傳最後是否看得到(不 assert,由呼叫端決定)。
    @MainActor
    @discardableResult
    func scrollIntoView(_ target: XCUIElement, in container: XCUIElement? = nil,
                        search: ScrollSearch = .both, limit: Int = 6, timeout: TimeInterval = 0) -> Bool {
        let keyboard = keyboards.firstMatch
        func isReachable() -> Bool {
            target.exists && target.isHittable && (!keyboard.exists || target.frame.maxY < keyboard.frame.minY)
        }
        if isReachable() { return true }
        let scroller = container ?? self
        if search != .up {
            for _ in 0..<limit where !isReachable() { scroller.swipeUp() }
        }
        if search != .down {
            for _ in 0..<limit where !isReachable() { scroller.swipeDown() }
        }
        return UITestWait.until(timeout: timeout, isReachable)
    }

    /// 帳號頁／設定頁等 sheet 是 lazy List:捲到元素出現。
    @MainActor
    @discardableResult
    func scrollSheet(_ sheetIdentifier: String, to target: XCUIElement, search: ScrollSearch = .both,
                     limit: Int = 8, timeout: TimeInterval = 0) -> Bool {
        scrollIntoView(target, in: element(sheetIdentifier), search: search, limit: limit, timeout: timeout)
    }

    /// 從 Agent 列表點開某台主機某個 Agent 的聊天(`agent.row.<主機身分>/<paneID>`;Demo 主機身分是 `demo`)。
    @MainActor
    func openConversation(paneID: String, host: String = "demo", file: StaticString = #filePath, line: UInt = #line) {
        let row = element("agent.row.\(host)/\(paneID)")
        XCTAssertTrue(reveal(row), "沒有看到 \(host) 主機的 Agent \(paneID)", file: file, line: line)
        row.tap()
    }

    /// 以 UI 測試模式啟動並進入某個 Demo 主機 Agent 的聊天。
    @MainActor
    static func launchUITestingConversation(paneID: String, host: String = "demo", flags: [String] = [],
                                            contentSize: String? = nil,
                                            file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = launchUITesting(flags: flags, contentSize: contentSize)
        app.openConversation(paneID: paneID, host: host, file: file, line: line)
        return app
    }

    /// 開帳號 sheet(一般字級點右上角帳號鈕;AX 字級在「⋯」選單裡)並等 `sheet.account` 出現。
    @MainActor
    func openAccountSheet(file: StaticString = #filePath, line: UInt = #line) {
        openAccount(file: file, line: line)
        XCTAssertTrue(element("sheet.account").waitUntilExists(timeout: 10), "沒有開出帳號頁", file: file, line: line)
    }

    /// 收起軟體鍵盤：還聚焦就點輸入列的「收起鍵盤」鈕，等鍵盤消失。沒有鍵盤時立刻返回
    /// (送出後鍵盤本來就會收起,#329;不為了「也許還在」多等)。
    @MainActor
    func dismissKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = keyboards.firstMatch
        guard keyboard.exists else { return }
        let hide = element("composer.hideKeyboard")
        var tapped = false
        let gone = UITestWait.until(timeout: 5) {
            if !tapped, hide.exists {
                hide.tap()
                tapped = true
            }
            return !keyboard.exists
        }
        XCTAssertTrue(gone, "鍵盤沒有收起", file: file, line: line)
    }

    /// 等鍵盤收起(自己按「完成」或 return 之後)。
    @MainActor
    func waitForKeyboardToHide(timeout: TimeInterval = 3) -> Bool {
        keyboards.firstMatch.waitUntilGone(timeout: timeout)
    }
}

extension XCUIApplication {
    /// 對話從底部開啟、列是 lazy 的：元素還沒建立或在畫面外時一次捲一點(先往下找較新的訊息，再往上找)，
    /// 直到它整個在對話區內。
    @MainActor
    @discardableResult
    func revealInConversation(_ target: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let list = scrollViews.firstMatch
        guard list.waitUntilExists(timeout: timeout) else { return false }
        _ = target.waitUntilExists(timeout: 3)
        for attempt in 0..<16 {
            let visible = visibleConversationRange(of: list)
            if target.exists, target.isHittable, target.frame.minY >= visible.lowerBound, target.frame.maxY <= visible.upperBound {
                return true
            }
            // 還沒排出來(LazyVStack 只排可見附近的列):先往下(較新的訊息)找幾次，再往上找(#251)。
            let isBelow = target.exists ? target.frame.midY > (visible.lowerBound + visible.upperBound) / 2 : attempt < 8
            // 在看得到的範圍裡拖，不從蓋在對話上的卡片開始。
            let height = visible.upperBound - visible.lowerBound
            let origin = coordinate(withNormalizedOffset: .zero)
            func point(_ fraction: CGFloat) -> XCUICoordinate {
                origin.withOffset(CGVector(dx: list.frame.midX, dy: visible.lowerBound + height * fraction))
            }
            let start = point(isBelow ? 0.8 : 0.2)
            let end = point(isBelow ? 0.3 : 0.7)
            start.press(forDuration: 0.1, thenDragTo: end)
            _ = target.waitUntilExists(timeout: 1)
        }
        return target.exists && target.isHittable
    }

    /// 對話真正看得到的範圍：導覽列下緣到輸入列上方的元素(建議卡、註記、停止列、輸入框)之間。
    /// 捲動視圖本身一路延伸到輸入列與導覽列底下，只看它的 frame 會點到蓋在上面的卡片(#251)。
    @MainActor
    func visibleConversationRange(of list: XCUIElement) -> ClosedRange<CGFloat> {
        let top = max(list.frame.minY, navigationBars.firstMatch.frame.maxY)
        let covers = ["conversation.suggestion", "youShouldKnow.note", "youShouldKnow.compact", "stopBar.stop", "composer.text"]
            .map { element($0) }
            .filter(\.exists)
            .map { $0.frame.minY - 8 }
        let bottom = min(list.frame.maxY, covers.min() ?? list.frame.maxY)
        return top...max(top, bottom)
    }
}
