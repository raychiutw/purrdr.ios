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
        // iPad 兩欄時第一個 collection view 是左邊的 Agent 列表(對話欄在它後面)。
        let list = collectionViews.firstMatch
        guard list.waitUntilExists(timeout: timeout) else { return false }
        // 列表載入中：先等一下;畫面上的列都建好之後還是沒有，才往下捲。
        if !row.waitUntilExists(timeout: min(timeout, 4)) {
            // AX 字級時每列很高,列表比預設字級長好幾倍:多拖幾次才到得了最後一段。
            for _ in 0..<24 where !row.exists {
                drag(list)
            }
            guard row.waitUntilExists(timeout: max(timeout - 4, 1)) else { return false }
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

/// 聊天列(Spaces 的 Tab 列,#501 起聊天只有 Spaces)的識別碼。Demo 主機每個 workspace 只有一個 Tab:`w1:p1` 在 `w1:t1`。
/// 同一個 Tab 有多個 Pane 的(Demo 的 `w3`)是版面圖列:點開後在版面圖選 Pane(`layout.block.<paneID>`)。
func chatRowID(_ paneID: String, host: String = "demo") -> String {
    let workspace = paneID.split(separator: ":").first.map(String.init) ?? paneID
    return "spaces.tab.\(host)/\(workspace):t1"
}

extension XCUIApplication {
    /// 第一階 tab 頂列的搜尋欄(#615:系統 `searchable`,沒有自訂識別碼,一個畫面只有一個搜尋欄)。
    var chatSearch: XCUIElement { searchFields.firstMatch }

    /// 聊天搜尋欄平常收起(`displayMode: .automatic`,與系統「訊息」一致):還沒出現就在列表往下拉,再回傳搜尋欄。
    @MainActor
    func revealChatSearch(timeout: TimeInterval = 5) -> XCUIElement {
        if !chatSearch.waitUntilExists(timeout: 1) {
            let list = collectionViews.firstMatch
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
        _ = chatSearch.waitUntilExists(timeout: timeout)
        return chatSearch
    }

    /// 第一階 tab 的大標題(#615:系統導覽列的大標題,識別碼 `topBar.title` 已不存在,以標題文字找)。
    func topBarTitle(_ title: String) -> XCUIElement { navigationBars.staticTexts[title].firstMatch }

    /// 聊天列表已經出現(取代舊的 Agents／Spaces 切換鈕:用來等列表載入完成;頂列的新增聊天鈕一直都在)。
    var chatListReady: XCUIElement { buttons["toolbar.newChat"].firstMatch }

    /// 左上角的主機篩選選了某一項(#244)。
    @MainActor
    func filterHosts(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let filter = buttons["toolbar.currentHost"].firstMatch
        XCTAssertTrue(filter.waitUntilExists(timeout: 10), "左上角沒有主機篩選", file: file, line: line)
        filter.tap()
        let item = buttons[name].firstMatch
        XCTAssertTrue(item.waitUntilExists(timeout: 5), "主機篩選選單沒有 \(name)", file: file, line: line)
        item.tap()
    }
}

/// 頂層 tab(#390、#503:設定併進帳號 sheet,只有四個;名稱是 tab bar 按鈕的英文標籤)。
enum AppTab: String {
    case chats = "Chats"
    case files = "Files"
    case hosts = "Hosts"
    case traffic = "Traffic"

    /// 繁體中文介面的 tab 標籤。
    var traditionalChinese: String {
        switch self {
        case .chats: "聊天"
        case .files: "檔案"
        case .hosts: "主機"
        case .traffic: "流量"
        }
    }
}

extension XCUIApplication {
    /// 點底部 tab bar 的 tab(聊天 tab 有「需要你」badge 時標籤尾端會多念數量,所以比對開頭)。
    @MainActor
    func openTab(_ tab: AppTab, file: StaticString = #filePath, line: UInt = #line) {
        // iPad 寬視窗的 tab bar 在上方(浮動工具列),不一定在 `tabBars` 底下:找不到再找一般按鈕。
        let labels = NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", tab.rawValue, tab.traditionalChinese)
        var button = tabBars.buttons.matching(labels).firstMatch
        if !button.waitUntilExists(timeout: 3) {
            button = buttons.matching(labels).firstMatch
        }
        XCTAssertTrue(button.waitUntilExists(timeout: 10), "tab bar 沒有 \(tab.rawValue)", file: file, line: line)
        if !button.isSelected { button.tap() }
    }

    /// 設定(#503:併在帳號與設定 sheet 的第一層):點帳號鈕開 sheet。沒登入時第一層是「登入或加入」選擇頁(`account.signedOut`),
    /// 登入後是帳號頁(`sheet.account`);兩種都帶著設定的段落。
    @MainActor
    func openSettingsSheet(file: StaticString = #filePath, line: UInt = #line) {
        openAccount(file: file, line: line)
        waitForAccountSheet(file: file, line: line)
    }

    /// 等帳號與設定 sheet 出現(`sheet.account` 或沒登入的 `account.signedOut`)。
    @MainActor
    func waitForAccountSheet(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            UITestWait.until(timeout: 10) { self.element("sheet.account").exists || self.element("account.signedOut").exists },
            "沒有開出帳號與設定", file: file, line: line)
    }

    /// modal 的關閉鈕在左上、確認 ✓ 在右上(#613):以按鈕中心相對視窗中線判斷。
    @MainActor
    func assertModalToolbar(close: String, confirm: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let midX = windows.firstMatch.frame.midX
        let closeButton = buttons[close].firstMatch
        XCTAssertTrue(closeButton.waitUntilExists(timeout: 5), "沒有關閉鈕 \(close)", file: file, line: line)
        XCTAssertLessThan(closeButton.frame.midX, midX, "關閉鈕不在左上", file: file, line: line)
        if let confirm {
            let confirmButton = buttons[confirm].firstMatch
            XCTAssertTrue(confirmButton.exists, "沒有確認 ✓ \(confirm)", file: file, line: line)
            XCTAssertGreaterThan(confirmButton.frame.midX, midX, "確認 ✓ 不在右上", file: file, line: line)
        }
    }

    /// 以左上角「X」關閉帳號與設定 sheet(#503、#613)並等它消失。
    @MainActor
    func closeAccountSheet(file: StaticString = #filePath, line: UInt = #line) {
        let close = buttons["member.close"].exists ? buttons["member.close"] : buttons["member.signIn.cancel"]
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "帳號與設定沒有左上角 X", file: file, line: line)
        XCTAssertLessThan(close.frame.midX, windows.firstMatch.frame.midX, "帳號與設定的 X 不在左上", file: file, line: line)
        close.tap()
        XCTAssertTrue(
            UITestWait.until(timeout: 5) { !self.element("sheet.account").exists && !self.element("account.signedOut").exists },
            "按 X 後帳號與設定沒有關閉", file: file, line: line)
    }

    /// 主機 tab(單台主機總頁;右上的新增主機鈕一直都在)。
    @MainActor
    func openHostsTab(file: StaticString = #filePath, line: UInt = #line) {
        openTab(.hosts, file: file, line: line)
        scrollToTopBar(containing: "hosts.add")
        XCTAssertTrue(buttons["hosts.add"].waitUntilExists(timeout: 10), "沒有開出主機 tab", file: file, line: line)
    }

    /// 聊天 tab 右上的新增聊天(`square.and.pencil`)。
    @MainActor
    func openNewChat(file: StaticString = #filePath, line: UInt = #line) {
        openTab(.chats, file: file, line: line)
        let button = buttons["toolbar.newChat"].firstMatch
        XCTAssertTrue(button.waitUntilExists(timeout: 10), "聊天 tab 沒有新增聊天", file: file, line: line)
        button.tap()
    }

    /// 帳號鈕(#246)開帳號頁，再點步驟卡的「加入」進登入頁(UI 測試沒有會員後台，一律未加入會員)。
    @MainActor
    func openSignInFromAccount(file: StaticString = #filePath, line: UInt = #line) {
        // 沒登入時帳號頁先選登入或加入(#408):選「登入」進登入頁。
        openAccount(file: file, line: line)
        let signIn = buttons["account.entry.signIn"].firstMatch
        XCTAssertTrue(element("account.signedOut").waitUntilExists(timeout: 10), "帳號頁沒有選擇頁", file: file, line: line)
        // 大字級下選擇頁的列在畫面外(lazy,不在 accessibility tree):先捲到看得到。
        scrollIntoView(signIn, search: .down)
        XCTAssertTrue(signIn.waitUntilExists(timeout: 5), "選擇頁沒有「登入」", file: file, line: line)
        signIn.tap()
        XCTAssertTrue(buttons["member.signIn.apple"].firstMatch.waitUntilExists(timeout: 10), "沒有登入頁", file: file, line: line)
    }

    /// 主機 tab 總頁的一列(`hosts.edit`、`hosts.share`…):清單是 lazy 的,先捲到看得到再回傳。
    @MainActor
    func overviewRow(_ identifier: String) -> XCUIElement {
        let row = buttons[identifier].firstMatch
        _ = row.waitUntilExists(timeout: 10)
        scrollIntoView(row, timeout: 5)
        return row
    }

    /// 主機 tab 右上電腦圖示選單(#616)選了某一台(選單的項目名稱是主機名稱)。
    @MainActor
    func selectHostOnHostsTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = buttons["hosts.host"].firstMatch
        XCTAssertTrue(picker.waitUntilExists(timeout: 10), "主機 tab 右上沒有電腦圖示選單", file: file, line: line)
        picker.tap()
        let item = buttons[name].firstMatch
        XCTAssertTrue(item.waitUntilExists(timeout: 5), "主機選單沒有 \(name)", file: file, line: line)
        item.tap()
    }

    /// 開已存主機(`-seedHost` 的 Studio Mac,啟動時就是選取中主機)的「這台主機的設定」頁(#392):
    /// 主機主題、You should know、Codex 啟動器在這裡。
    @MainActor
    func openSeededHostSettings(file: StaticString = #filePath, line: UInt = #line) {
        openHostsTab(file: file, line: line)
        let settings = overviewRow("hosts.settings")
        XCTAssertTrue(settings.waitUntilExists(timeout: 10), "主機 tab 沒有「這台主機的設定」", file: file, line: line)
        settings.tap()
        XCTAssertTrue(element("hosts.settings.page").waitUntilExists(timeout: 10), "沒有開出這台主機的設定", file: file, line: line)
    }

    /// 開已存主機(`-seedHost` 的 Studio Mac)的「編輯主機」頁(#392:名稱、圖示、連線方式)。
    @MainActor
    func openSeededHostEditor(file: StaticString = #filePath, line: UInt = #line) {
        openHostsTab(file: file, line: line)
        let edit = overviewRow("hosts.edit")
        XCTAssertTrue(edit.waitUntilExists(timeout: 10), "主機 tab 沒有「編輯主機」", file: file, line: line)
        edit.tap()
        XCTAssertTrue(textFields["hostEditor.name"].firstMatch.waitUntilExists(timeout: 10), "沒有開出編輯主機", file: file, line: line)
    }

    /// 開帳號頁:點右上角的帳號鈕(每個 tab 都有;AX 字級時系統把它收進工具列的溢出選單,#268)。
    @MainActor
    func openAccount(file: StaticString = #filePath, line: UInt = #line) {
        tapToolbarItem("toolbar.account", overflowLabel: "Account", file: file, line: line)
    }

    /// 打開對話右上角的「更多」選單並回傳其中的項目(`terminal.open`、`changes.open`、`layout.show`,#381)。
    @MainActor
    func conversationMoreItem(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        // 系統選單分段後不帶項目的 identifier,以標題(英文)找。
        let titles = [
            "menu.usage": "Usage & Context", "menu.permissionMode": "Permission Mode", "menu.model": "Model & Effort",
            "menu.sendWhenDone": "Send When Done", "menu.todos": "Todos", "menu.backgroundAgents": "Background Agents",
            "terminal.open": "Pane Terminal", "changes.open": "Git Changes", "layout.show": "Show Layout",
        ]
        let item = buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", identifier, (titles[identifier] ?? identifier) + ",")).firstMatch
        // 選單內容在打開當下就定了:項目依聊天讀到的狀態(Agent 種類、模型)出現,還沒讀到就收起來重開。
        for _ in 0..<6 {
            tapToolbarItem("conversation.more", overflowLabel: "More", file: file, line: line)
            if item.waitUntilExists(timeout: 2) { return item }
            windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            _ = UITestWait.until(timeout: 2) { !self.buttons["terminal.open"].firstMatch.exists && !self.buttons["changes.open"].firstMatch.exists }
        }
        XCTAssertTrue(item.exists, "「更多」選單沒有 \(identifier)", file: file, line: line)
        return item
    }

    /// 往下捲過的頁面頂列會收合(收合後只剩小標題、不渲染右側的按鈕):要點頂列按鈕前先把頁面捲回最上面。
    /// 按鈕已經在畫面上就不動;捲不回來不在這裡失敗(後面的斷言會說明找不到什麼)。
    @MainActor
    func scrollToTopBar(containing identifier: String) {
        guard !buttons[identifier].firstMatch.waitUntilExists(timeout: 1),
              !buttons["OverflowBarButtonItem"].firstMatch.exists else { return }
        for _ in 0..<10 where !buttons[identifier].firstMatch.exists {
            windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
    }

    /// 點工具列右側的項目。AX 字級時系統把右側的項目收進工具列的溢出選單(More):
    /// 選單項目沒有 identifier,以 VoiceOver 也會念的名稱找(名稱不對就是 a11y 問題)。
    @MainActor
    func tapToolbarItem(_ identifier: String, overflowLabel: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = buttons[identifier].firstMatch
        let overflow = buttons["OverflowBarButtonItem"].firstMatch
        scrollToTopBar(containing: identifier)
        XCTAssertTrue(UITestWait.until(timeout: 15) { item.exists || overflow.exists }, "工具列沒有 \(identifier) 也沒有溢出選單", file: file, line: line)
        if item.exists {
            item.tap()
            return
        }
        overflow.tap()
        // 溢出鈕自己的名稱也是「More」。
        let overflowItem = buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", overflowLabel, "OverflowBarButtonItem")).firstMatch
        XCTAssertTrue(overflowItem.waitUntilExists(timeout: 5), "溢出選單裡沒有「\(overflowLabel)」", file: file, line: line)
        overflowItem.tap()
    }

    /// 付費牆沒有固定入口,未加入會員時帳號頁也還沒有「開通」:以深層連結開(#246)。
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
        // `for … where` 條件不成立時不會結束迴圈,而是空轉剩下的次數、每次還是查詢鍵盤(每次 typeEnglish 白白多約 1 秒):
        // 已經是指定的輸入法就第一次檢查後直接返回。
        for _ in 0..<5 {
            if markers.contains(where: { keyboard.keys[$0].exists }) || !nextKeyboard.exists { return }
            nextKeyboard.tap()
        }
    }
}

extension XCUIElement {
    /// 以英文軟體鍵盤打字：注音等輸入法會把英文變成組字。
    @MainActor
    func typeEnglish(_ text: String) {
        // 點下輸入框後焦點要一下子才到：沒有焦點就 typeText 會失敗。
        _ = wait(timeout: 3) { ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        XCUIApplication().switchKeyboard(to: .english)
        typeText(text)
    }
}

extension XCUIApplication {
    /// 輸入列要「需要第二行、有換行或有附件」才展開(#512):點輸入框後打一個換行，露出模型膠囊。
    @MainActor
    func expandComposer() {
        let text = element("composer.text")
        text.tap()
        text.typeEnglish("\n")
    }

    /// 不重啟換字級(#373):以測試連結 `purrdr://testing-content-size` 把字級類別套到視窗(只在 `-uiTesting` 生效)。
    /// `nil` 回到系統字級。換完等畫面停下。
    @MainActor
    func setContentSize(_ category: String?) {
        var link = "purrdr://testing-content-size"
        if let category { link += "?category=\(category)" }
        open(URL(string: link)!)
        waitForVisualSettle()
    }
}

extension XCUIApplication {
    /// 不重啟換淺色／深色(#373):以測試連結 `purrdr://testing-appearance` 套到視窗。`nil` 跟隨系統。
    @MainActor
    func setAppearance(_ style: String?) {
        var link = "purrdr://testing-appearance"
        if let style { link += "?style=\(style)" }
        open(URL(string: link)!)
        waitForVisualSettle()
    }
}
