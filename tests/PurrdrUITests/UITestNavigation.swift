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
    static let maxPollInterval: TimeInterval = 0.5

    /// 先立刻檢查一次，不成立才每隔 `pollInterval` 再查，到 `timeout` 為止。回傳條件最後是否成立。
    @MainActor
    static func until(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        if condition() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        var interval = pollInterval
        while Date() < deadline {
            // 用 run loop 睡，讓主執行緒仍處理 XCTest 的事件。
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
            if condition() { return true }
            // 每次取快照都在打擾 app 的主執行緒(終端機等忙碌畫面會被拖慢)：愈等愈疏，上限 0.5 秒。
            interval = min(interval * 1.5, maxPollInterval)
        }
        return condition()
    }
}

extension XCUIElement {
    /// 輸入框是不是鍵盤焦點(輸入列沒有收起鍵盤鈕可以當聚焦的訊號,#382)。
    var hasKeyboardFocus: Bool { value(forKey: "hasKeyboardFocus") as? Bool == true }

    /// 等元素出現(取代 `waitForExistence`:不固定多等 1 秒)。
    @MainActor
    @discardableResult
    func waitUntilExists(timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout: timeout) { existsWithoutIdle }
    }

    /// 出現後等位置停下來(最多 1 秒)：換頁、sheet 轉場中元素已經存在，但這時點下去會落空
    /// (舊的 `waitForExistence` 固定多等 1 秒，剛好把這件事遮住)。位置一直在變的元素等滿 1 秒就放行。
    /// 只給確定唯一的元素用(`firstMatch`):查詢有多個符合時取 `frame` 會失敗，所以不放進一般的 `waitUntilExists`。
    @MainActor
    @discardableResult
    func waitUntilExistsAndSettled(timeout: TimeInterval) -> Bool {
        guard waitUntilExists(timeout: timeout) else { return false }
        waitUntilFrameStops()
        return true
    }

    @MainActor
    func waitUntilFrameStops() {
        let deadline = Date().addingTimeInterval(1)
        var previous = frame
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            let current = frame
            if current == previous { return }
            previous = current
        }
    }

    /// 不等 app idle 的存在檢查(`waitForExistence` 內部用的 `existsNoRetry`)。
    /// 一般的 `exists` 會先等 app 閒置：畫面有持續動畫時一次就卡 60 秒，輪詢就變成輪流卡 60 秒。
    /// 等待用這個;已經確定畫面穩定、要斷言時才用 `exists`。
    @MainActor
    var existsWithoutIdle: Bool {
        Self.existsNoRetry.evaluate(with: self)
    }

    private static let existsNoRetry = NSPredicate(format: "existsNoRetry == 1")

    /// 等元素消失。
    @MainActor
    @discardableResult
    func waitUntilGone(timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout: timeout) { !existsWithoutIdle }
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

    /// 聊天頂列右上的用量環(#618:標題是系統導覽列標題,沒有識別碼;以這顆鈕當「聊天畫面已出現」的錨點)。
    var conversationBar: XCUIElement { buttons["conversation.usage"].firstMatch }

    /// 聊天頂列的系統副標題(只有狀態文字):導覽列裡含指定文字的靜態文字。
    func conversationSubtitle(containing text: String) -> XCUIElement {
        navigationBars.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 從聊天列表(Spaces)點開某台主機某個 Agent 的聊天(Tab 列 `spaces.tab.<主機身分>/<tab>`,見 `chatRowID`;Demo 主機身分是 `demo`)。
    /// Tab 有多個 Pane(Demo 的 `w3`)時先開版面圖、再點 Agent 方塊。
    @MainActor
    func openConversation(paneID: String, host: String = "demo", file: StaticString = #filePath, line: UInt = #line) {
        let row = element(chatRowID(paneID, host: host))
        XCTAssertTrue(reveal(row), "沒有看到 \(host) 主機的 Agent \(paneID)", file: file, line: line)
        row.tap()
        let block = buttons["layout.block.\(paneID)"]
        if block.waitUntilExists(timeout: 2) { block.tap() }
        // 推進聊天畫面的轉場中，標題列的按鈕已經存在但點不到：等標題列停下。
        XCTAssertTrue(conversationBar.waitUntilExistsAndSettled(timeout: 15), "沒有開出聊天畫面", file: file, line: line)
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

    /// 開帳號 sheet(點右上角帳號鈕;AX 字級在溢出選單裡)並等 `sheet.account` 出現。
    @MainActor
    func openAccountSheet(file: StaticString = #filePath, line: UInt = #line) {
        openAccount(file: file, line: line)
        XCTAssertTrue(element("sheet.account").waitUntilExists(timeout: 10), "沒有開出帳號頁", file: file, line: line)
    }

    /// 帳號頁捲到「Notifications」列並點開子頁(逐台主機的通知開關在那裡,#463)。
    @MainActor
    func openAccountNotifications(file: StaticString = #filePath, line: UInt = #line) {
        let link = element("account.notifications")
        XCTAssertTrue(scrollSheet("sheet.account", to: link, search: .down, timeout: 10), "帳號頁沒有通知入口", file: file, line: line)
        link.tap()
        XCTAssertTrue(element("account.notifications.page").waitUntilExists(timeout: 10), "沒有進到通知子頁", file: file, line: line)
    }

    /// 收起軟體鍵盤：點對話的空白處(輸入列沒有收起鍵盤鈕,#382),等鍵盤消失。沒有鍵盤時立刻返回
    /// (送出後鍵盤本來就會收起,#329;不為了「也許還在」多等)。
    @MainActor
    func dismissKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = keyboards.firstMatch
        guard keyboard.exists else { return }
        var tapped = false
        let gone = UITestWait.until(timeout: 5) {
            if !tapped {
                windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
                tapped = true
            }
            return !keyboard.exists
        }
        XCTAssertTrue(gone, "鍵盤沒有收起", file: file, line: line)
        // 鍵盤收起後輸入列與對話還在動(捲回最新一列)：等版面停下再讓測試去點。
        _ = waitForSettledLayout([element("composer.text")], timeout: 3)
    }

    /// 等這些元素的位置連續兩次取樣都不變(動畫、捲動停下)。
    @MainActor
    @discardableResult
    func waitForSettledLayout(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = elements.map(\.frame)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let current = elements.map(\.frame)
            if current == previous { return true }
            previous = current
        }
        return false
    }

    /// 等軟體鍵盤出現並停止移動(動畫中點擊或滑動會落在還沒定位的版面上)。
    @MainActor
    @discardableResult
    func waitForKeyboard(timeout: TimeInterval = 5) -> Bool {
        let keyboard = keyboards.firstMatch
        guard keyboard.waitUntilExists(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(3)
        var previous = keyboard.frame
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let current = keyboard.frame
            if current == previous { return true }
            previous = current
        }
        return false
    }

    /// 對話列表(`UICollectionView`,ADR-0014);原本的 `ScrollView` 查詢改指到它。
    @MainActor
    var conversationList: XCUIElement { collectionViews["conversation.list"] }

    /// 點文字欄叫出鍵盤,以「欄位真的取得焦點」為準:剛推進頁面時欄位的轉場還沒停,第一下點擊可能落空
    /// (只有那一下沒有焦點,鍵盤就不會出現);焦點沒到就再點,最多 3 次。
    @MainActor
    func focusTextField(_ field: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard field.waitUntilHittable(timeout: timeout) else { return false }
        for _ in 0..<3 {
            field.tap()
            if field.wait(timeout: 2, until: { ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true }) { return true }
        }
        return false
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
        let list = conversationList
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

extension XCUIApplication {
    /// 等整個畫面停下來：連續兩張截圖相同(最多等 `timeout` 秒;有永遠在動的元素就放行)。
    /// 比對的是像素，不受查詢是否唯一影響;每張截圖約 0.2 秒，只給稽核這類要量畫面的地方用。
    @MainActor
    @discardableResult
    func waitForVisualSettle(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = screenshot().pngRepresentation
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let current = screenshot().pngRepresentation
            if current == previous { return true }
            previous = current
        }
        return false
    }
}

extension XCUIApplication {
    /// 終端機的標題與副標題(系統導覽列的標題＋副標題,#621):名稱與連線狀態,以「 | 」連起來。
    @MainActor
    var terminalHeader: String {
        navigationBars.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
    }

    /// 等終端機的標題或狀態含指定文字。
    @MainActor
    func waitForTerminalHeader(containing text: String, timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout: timeout) { terminalHeader.contains(text) }
    }
}
