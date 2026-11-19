import XCTest

extension XCUIApplication {
    /// 以 UI 測試模式啟動 app:`-uiTesting` 一律帶(只用 Demo 主機、不連網路)。
    ///
    /// UI 測試一律經過這裡(或 `uiTesting`)啟動，不在測試檔裡自己拼 `launchArguments`。
    /// `flags` 是情境旗標;`contentSize` 是系統字級類別(例如 `UICTContentSizeCategoryAccessibilityXXXL`)。
    @MainActor
    static func launchUITesting(flags: [String] = [], contentSize: String? = nil) -> XCUIApplication {
        let app = uiTesting(flags: flags, contentSize: contentSize)
        app.launch()
        return app
    }

    /// 設定好 UI 測試啟動參數、但還沒啟動的 app。給要由 `open(_:)`(深層連結)冷啟動的測試用。
    @MainActor
    static func uiTesting(flags: [String] = [], contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        // 介面語言固定英文(斷言用英文字);模擬器系統語言可能是繁中。要測繁中時在 flags 帶 `-AppleLanguages`。
        let language = flags.contains("-AppleLanguages") ? [] : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = ["-uiTesting"] + flags + language
            + (contentSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        return app
    }
}

extension XCUIApplication {
    /// 列被底部工具列(搜尋欄)蓋住時，把列表往上拖到列整個露出來，再滑動或點它。
    /// 列表上方有「You should know」列(#23)、各組標題帶數量(#41)時，最後一組的列會落在工具列底下，
    /// 這時滑動與點擊會打在工具列上。
    ///
    /// Spaces 檢視(#40)的卡片較高，最後一組的列可能整個在畫面外;列表是 lazy,這時列還不在 accessibility tree 裡，
    /// 所以先等列表載入，列不存在就一次往下捲一點，直到列出現。回傳列最後是否存在(取代 `waitForExistence`)。
    @MainActor
    @discardableResult
    func reveal(_ row: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        // iPad 三欄時第一個 collection view 是側欄;捲的是 Agent 列表。
        let list = collectionViews.matching(NSPredicate(format: "identifier != %@", "sidebar")).firstMatch
        guard list.waitForExistence(timeout: timeout) else { return false }
        // 列表載入中：先等一下;畫面上的列都建好之後還是沒有，才往下捲。
        if !row.waitForExistence(timeout: min(timeout, 4)) {
            for _ in 0..<8 where !row.exists {
                drag(list)
            }
            guard row.waitForExistence(timeout: max(timeout - 4, 1)) else { return false }
        }
        let limit = windows.firstMatch.frame.maxY - 150
        for _ in 0..<3 where row.frame.maxY > limit {
            drag(list)
        }
        return row.exists
    }

    /// 把列表往上拖四分之一高(內容往下捲)。
    @MainActor
    private func drag(_ list: XCUIElement) {
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
    }
}

extension XCUIApplication {
    /// 點列表工具列的「⋯」再點選單項目(新增聊天也在選單裡，#241)。
    @MainActor
    func openMoreMenuItem(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let more = buttons["toolbar.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "列表工具列沒有「⋯」", file: file, line: line)
        more.tap()
        let item = buttons[identifier].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "「⋯」選單沒有 \(identifier)", file: file, line: line)
        item.tap()
    }

    /// 會員不在「⋯」選單(#241):從設定頁的會員列進入。
    @MainActor
    func openMemberFromSettings(file: StaticString = #filePath, line: UInt = #line) {
        openMoreMenuItem("menu.settings", file: file, line: line)
        let member = buttons["settings.member"].firstMatch
        XCTAssertTrue(member.waitForExistence(timeout: 10), "設定頁沒有會員列", file: file, line: line)
        member.tap()
    }

    /// Purrdr Plus 不在「⋯」選單(#241):沒訂閱時從設定頁的主機同步進入付費牆。
    @MainActor
    func openPlusFromSettings(file: StaticString = #filePath, line: UInt = #line) {
        openMoreMenuItem("menu.settings", file: file, line: line)
        let toggle = descendants(matching: .any)["settings.hostSync"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "設定頁沒有主機同步", file: file, line: line)
        // 點開關本身(列的右側)。
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let plus = descendants(matching: .any)["settings.hostSync.plus"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "沒有顯示需要 Purrdr Plus", file: file, line: line)
        plus.tap()
    }
}
