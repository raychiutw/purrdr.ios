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
    /// 聊天列表的大標題(目前檢視名，#244 起是靜態文字)。
    var listLargeTitle: XCUIElement { staticTexts["agentList.title"].firstMatch }

    /// 點大標題下的 Agents／Spaces 分段切換(#244)。
    @MainActor
    func switchListMode(to mode: String, file: StaticString = #filePath, line: UInt = #line) {
        let control = segmentedControls["agentList.mode"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15), "大標題下沒有 Agents／Spaces 切換", file: file, line: line)
        control.buttons[mode].tap()
    }

    /// 左上角的主機篩選選了某一項(#244)。
    @MainActor
    func filterHosts(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let filter = buttons["toolbar.hostFilter"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 10), "左上角沒有主機篩選", file: file, line: line)
        filter.tap()
        let item = buttons[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "主機篩選選單沒有 \(name)", file: file, line: line)
        item.tap()
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

    /// 帳號鈕(#246)開帳號頁，再點步驟卡的「加入」進登入頁(UI 測試沒有會員後台，一律未加入會員)。
    @MainActor
    func openSignInFromAccount(file: StaticString = #filePath, line: UInt = #line) {
        let account = buttons["toolbar.account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), "列表右上角沒有帳號鈕", file: file, line: line)
        account.tap()
        let join = buttons["account.plusSetup.action"].firstMatch
        XCTAssertTrue(join.waitForExistence(timeout: 10), "帳號頁沒有「加入」", file: file, line: line)
        join.tap()
    }

    /// 付費牆不在「⋯」選單(#241),未加入會員時帳號頁也還沒有「開通」:以深層連結開(#246)。
    @MainActor
    func openPlusPaywall() {
        open(URL(string: "purrdr://plus")!)
    }
}

/// 觸控目標至少 44×44pt。畫面座標是浮點數，44pt 的按鈕可能量成 43.99999999999994,只容許浮點誤差。
@MainActor
func XCTAssertHitTarget(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    let floatingPointError = 0.001
    XCTAssertGreaterThanOrEqual(
        element.frame.width + floatingPointError, 44, "\(element.identifier) 寬度不到 44pt:\(element.frame)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(
        element.frame.height + floatingPointError, 44, "\(element.identifier) 高度不到 44pt:\(element.frame)", file: file, line: line)
}

/// 軟體鍵盤的輸入法。模擬器用系統鍵盤清單的第一個或上次用的(`-AppleKeyboards` 啟動參數不會換掉它)。
enum KeyboardLayout {
    case english
    case zhuyin
}

extension XCUIApplication {
    /// 軟體鍵盤不是指定的輸入法時按地球鍵切過去(切換會被模擬器記成上次用的)。沒有軟體鍵盤時不做事。
    @MainActor
    func switchKeyboard(to layout: KeyboardLayout) {
        let keyboard = keyboards.firstMatch
        guard keyboard.exists else { return }
        let markers = layout == .english ? ["q", "Q"] : ["ㄅ"]
        // 地球鍵在鍵盤元素外(底部 home indicator 旁)。
        let nextKeyboard = buttons["Next keyboard"].firstMatch
        for _ in 0..<5 where !markers.contains(where: { keyboard.keys[$0].exists }) && nextKeyboard.exists {
            nextKeyboard.tap()
        }
    }
}

extension XCUIElement {
    /// 以英文軟體鍵盤打字：注音等輸入法會把英文變成組字。
    @MainActor
    func typeEnglish(_ text: String) {
        XCUIApplication().switchKeyboard(to: .english)
        typeText(text)
    }
}
