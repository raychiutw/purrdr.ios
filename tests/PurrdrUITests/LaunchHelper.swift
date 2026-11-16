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
    @MainActor
    func reveal(_ row: XCUIElement) {
        let list = collectionViews.firstMatch
        let limit = windows.firstMatch.frame.maxY - 150
        for _ in 0..<3 where row.frame.maxY > limit {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
    }
}
