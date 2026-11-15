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
        app.launchArguments = ["-uiTesting"] + flags
            + (contentSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        return app
    }
}
