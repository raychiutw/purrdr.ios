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
    /// 聊天列表最上面的 Agents／Spaces 切換(#268:沒有大標題，檢視只看這裡;#313:攤開成兩列勾選)。以「Agents」那一列代表。
    /// inline Picker 的每一列都帶 Picker 的 identifier(`agentList.mode`),依順序取：第 0 列 Agents、第 1 列 Spaces(繁中介面也找得到)。
    var listModeControl: XCUIElement { listModeRow(0) }

    private func listModeRow(_ index: Int) -> XCUIElement {
        buttons.matching(identifier: "agentList.mode").element(boundBy: index)
    }

    /// 目前選到的檢視(「Agents」或「Spaces」那一列)。
    var listModeSelection: XCUIElement {
        buttons.matching(NSPredicate(format: "identifier == 'agentList.mode' AND isSelected == true")).firstMatch
    }

    /// 點 Agents／Spaces 那一列(#244、#268、#313)。
    @MainActor
    func switchListMode(to mode: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(listModeControl.waitForExistence(timeout: 15), "沒有 Agents／Spaces 切換", file: file, line: line)
        listModeRow(mode == "Spaces" ? 1 : 0).tap()
    }

    /// 左上角的主機篩選選了某一項(#244)。
    @MainActor
    func filterHosts(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let filter = buttons["toolbar.currentHost"].firstMatch
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
        openAccount(file: file, line: line)
        let join = buttons["account.plusSetup.action"].firstMatch
        XCTAssertTrue(join.waitForExistence(timeout: 10), "帳號頁沒有「加入」", file: file, line: line)
        join.tap()
    }

    /// 開已存主機(`-seedHost` 的 Studio Mac)的主機頁(#274:主機主題、You should know、Codex 啟動器在這裡)。
    @MainActor
    func openSeededHostPage(file: StaticString = #filePath, line: UInt = #line) {
        let more = buttons["toolbar.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "列表工具列沒有「⋯」", file: file, line: line)
        more.tap()
        buttons["menu.hosts"].firstMatch.tap()
        let info = buttons["hosts.info.5EED0000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10), "主機清單沒有 Studio Mac 的 ⓘ", file: file, line: line)
        info.tap()
        XCTAssertTrue(textFields["hostEditor.name"].firstMatch.waitForExistence(timeout: 10), "沒有開出主機頁", file: file, line: line)
    }

    /// 開帳號頁：一般字級點右上角的帳號鈕;AX 字級時帳號併在「⋯」選單裡(#268)。
    @MainActor
    func openAccount(file: StaticString = #filePath, line: UInt = #line) {
        let account = buttons["toolbar.account"].firstMatch
        if account.waitForExistence(timeout: 5) {
            account.tap()
            return
        }
        let more = buttons["toolbar.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "工具列沒有帳號鈕也沒有「⋯」", file: file, line: line)
        more.tap()
        let item = buttons["menu.account"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "「⋯」選單沒有帳號", file: file, line: line)
        item.tap()
    }

    /// 點列表工具列右側的項目。AX 字級時系統把右側的「⋯」與帳號鈕收進工具列的溢出選單(More):
    /// 選單項目沒有 identifier,以 VoiceOver 也會念的名稱找(名稱不對就是 a11y 問題)。
    @MainActor
    func tapToolbarItem(_ identifier: String, overflowLabel: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = buttons[identifier].firstMatch
        let overflow = buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10) || overflow.exists, "工具列沒有 \(identifier) 也沒有溢出選單", file: file, line: line)
        if item.exists {
            item.tap()
            return
        }
        overflow.tap()
        // 溢出鈕自己的名稱也是「More」。
        let overflowItem = buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", overflowLabel, "OverflowBarButtonItem")).firstMatch
        XCTAssertTrue(overflowItem.waitForExistence(timeout: 5), "溢出選單裡沒有「\(overflowLabel)」", file: file, line: line)
        overflowItem.tap()
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
