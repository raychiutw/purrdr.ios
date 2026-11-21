import XCTest

extension XCUIApplication {
    /// 觸發 Demo 情境的事件(#371):斷網、大量輸出、工作結束、Tailscale 驗證完成。
    /// 不靠牆鐘：測試在畫面準備好之後才呼叫。觸發鈕只在 `-uiTesting` 且情境需要觸發時存在，是畫面左上角 2pt 的按鈕，以座標點擊。
    @MainActor
    func triggerDemoScenario(file: StaticString = #filePath, line: UInt = #line) {
        let trigger = descendants(matching: .any)["uiTesting.demoTrigger"].firstMatch
        XCTAssertTrue(trigger.waitForExistence(timeout: 5), "這個情境沒有觸發鈕", file: file, line: line)
        trigger.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// 輪詢到條件成立(先檢查一次，之後每 0.1 秒)或到上限;回傳最後一次的結果。
    @MainActor
    func poll(timeout: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }
}
