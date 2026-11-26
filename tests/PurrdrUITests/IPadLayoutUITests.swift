import XCTest

/// iPad 兩欄(列表＋對話)、版面圖入口、鍵盤快捷鍵(#31、#518)。只在 iPad 模擬器跑(iPhone 上沒有分欄)。
final class IPadLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // XCTest 在主執行緒呼叫 setUp。
        let isPad = MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad }
        try XCTSkipUnless(isPad, "兩欄只在 iPad 的寬視窗出現")
    }

    @MainActor
    private func launchInLandscape() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        return XCUIApplication.launchUITesting()
    }

    /// 兩欄：Agent 列表、對話欄(沒有側欄);點列後對話開在列表旁，列表還在。
    @MainActor
    func testTwoColumnsShowChatBesideList() {
        let app = launchInLandscape()

        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Agent 列表")
        XCTAssertTrue(app.element("detail.empty").exists, "對話欄沒有「Select a Chat」")
        // 沒有側欄:列表在視窗最左邊(左邊沒有別的欄)，而且只佔一部分寬度(右邊是對話欄)。
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(row.frame.minX, window.minX + window.width * 0.1, "列表左邊還有別的欄(側欄?)")
        XCTAssertLessThan(row.frame.maxX, window.minX + window.width * 0.6, "列表佔了太寬，對話欄放不下")

        row.tap()

        XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 10), "對話沒有開在對話欄")
        XCTAssertTrue(row.exists, "對話推走了列表(應該在列表旁)")
        XCTAssertLessThan(row.frame.maxX, app.element("conversation.user").frame.minX, "對話沒有在列表的右邊")
    }

    /// 選取列是中性灰底(#238):底色無彩度、與未選取的列不同，不是主色。
    @MainActor
    func testSelectedRowUsesNeutralGray() throws {
        let app = launchInLandscape()
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Agent 列表")
        let unselectedColor = try rowBackgroundColor(row, in: app)

        row.tap()
        XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 10), "對話沒有開在對話欄")
        let selectedColor = try rowBackgroundColor(row, in: app)

        let chroma = max(selectedColor.red, selectedColor.green, selectedColor.blue) - min(selectedColor.red, selectedColor.green, selectedColor.blue)
        XCTAssertLessThanOrEqual(chroma, 8, "選取底不是中性灰:\(selectedColor)")
        XCTAssertNotEqual(selectedColor.red, unselectedColor.red, "選取列與未選取列底色相同:\(selectedColor)")
    }

    /// 取列頂端中央 2pt 處(列的內距，沒有文字)的像素。
    @MainActor
    private func rowBackgroundColor(_ row: XCUIElement, in app: XCUIApplication) throws -> (red: Int, green: Int, blue: Int) {
        // 模擬器橫向時 `app.screenshot()` 的內容不是正的:改取整個螢幕的原始截圖(直向、介面順時針轉 90°),
        // 介面座標 (x, y) 對到影像 ((視窗高 - y) × scale, x × scale)。直向時座標直接對應。
        let cgImage = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let window = app.windows.firstMatch.frame
        let rotated = window.width > window.height && cgImage.height > cgImage.width
        let scale = CGFloat(cgImage.width) / (rotated ? window.height : window.width)
        let pointY = row.frame.minY + 3
        let pixelX = rotated ? Int((window.height - pointY) * scale) : Int(row.frame.midX * scale)
        let pixelY = rotated ? Int(row.frame.midX * scale) : Int(pointY * scale)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: -pixelX, y: pixelY - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// 列表欄沒有大標題(#268)也沒有檢視切換(#501:聊天只有 Spaces)。
    @MainActor
    func testListColumnHasOnlySpaces() {
        let app = launchInLandscape()
        let card = app.element("spaces.section.demo/w3")
        XCTAssertTrue(app.reveal(card), "沒有看到 Spaces")

        XCTAssertTrue(app.chatListReady.waitUntilExists(timeout: 5), "列表欄沒有頂列")
        XCTAssertFalse(app.buttons["agentList.mode"].exists, "列表欄不該有 Agents／Spaces 切換")
        XCTAssertFalse(app.staticTexts["agentList.title"].exists, "列表欄不該有大標題(#268)")
    }

    /// 版面圖只從 Spaces 的 Tab 列開(沒有側欄按鈕):多個 Pane 的 Tab 點了開版面圖，選 Agent 方塊,對話開在對話欄。
    @MainActor
    func testLayoutFromTabRowOpensChatBesideList() {
        let app = launchInLandscape()
        let tab = app.element("spaces.tab.demo/w3:t1")
        XCTAssertTrue(app.reveal(tab), "沒有看到 Spaces")

        tab.tap()
        let agentBlock = app.buttons["layout.block.w3:p1"]
        XCTAssertTrue(agentBlock.waitUntilExists(timeout: 5), "點多個 Pane 的 Tab 沒有開版面圖")
        XCTAssertFalse(app.element("layoutCard").exists, "不該再有浮動的版面圖卡片")

        agentBlock.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10), "版面圖選的 Agent 沒有開在對話欄")
        XCTAssertTrue(tab.exists, "對話推走了列表")
    }

    /// 硬體鍵盤：Option-Command-, 開 App 設定(Command-, 是系統的 Settings…,開 iOS 設定 app)。
    @MainActor
    func testAppSettingsShortcutOpensAccount() throws {
        let app = launchInLandscape()
        XCTAssertTrue(app.reveal(app.element("spaces.tab.demo/w1:t1")))

        app.openAccountWithShortcut()
        app.closeAccountSheet()
    }

    // MARK: - 無障礙稽核(#35)

    /// 兩欄(Agent 列表、對話開在對話欄):預設字級與 AX5 跑 accessibility audit。
    @MainActor
    func testAccessibilityAuditTwoColumns() throws {
        continueAfterFailure = true
        for size in [nil, AccessibilityAuditUITests.ax5] {
            XCUIDevice.shared.orientation = .landscapeLeft
            let app = XCUIApplication.launchUITesting(contentSize: size)
            let row = app.element("spaces.tab.demo/w2:t1")
            // AX5 時列表最上面的大標題(#66)換行變高，`reveal` 會把列表往上拖，列的上半段停在導覽列的玻璃底下
            // (中線剛好在 scroll edge effect 外，排除規則判斷不到)，audit 量到被模糊的那一塊。AX5 只等列出現、
            // 不捲動，稽核的是列表最上面(含大標題)的樣子。
            XCTAssertTrue(size == nil ? app.reveal(row) : row.waitUntilExists(timeout: 15), "沒有看到 Agent 列表")
            if size == nil {
                row.tap()
                XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 15), "對話沒有開在對話欄")
            }
            // AX5 時兩欄加上輪詢中的對話，audit 可能跑不完(「Audit failed to complete in time」,.tdd-logs/35-ipad-2.log);
            // AX5 只稽核列表(對話欄是「選一個對話」),對話畫面的 AX5 由 iPhone 的 audit 涵蓋。
            try audit(app, "iPad 兩欄", contentSize: size)
            app.terminate()
        }
    }
}
