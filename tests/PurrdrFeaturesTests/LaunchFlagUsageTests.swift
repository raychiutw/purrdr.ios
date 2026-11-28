import Foundation
import Testing

@testable import PurrdrFeatures

/// 啟動旗標的單一來源與守門(#698):每個 `LaunchFlag` 一定要有 UI 測試在用,UI 測試裡不能再有手寫的旗標字串。
/// 沒有測試使用的旗標只剩解析測試在守著,卻會跟著 Release 出貨(Demo 也在裡面),所以新增旗標時要同時寫用到它的 UI 測試。
@Suite("啟動旗標的使用守門")
struct LaunchFlagUsageTests {
    /// UI 測試原始碼(排除符號連結進來的 `LaunchFlag.swift` 本身)。
    private static func uiTestSources() throws -> [(name: String, text: String)] {
        let directory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "PurrdrUITests")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "LaunchFlag.swift" }
        try #require(!files.isEmpty, "找不到 UI 測試原始碼:\(directory.path)")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// 用到這個旗標的 UI 測試檔:`.旗標名稱` 後面不接識別字元,也不是呼叫(`XCUIApplication.uiTesting()` 是啟動函式)。
    private static func users(of flag: LaunchFlag, in sources: [(name: String, text: String)]) -> [String] {
        let pattern = "\\.\(flag)\\b(?!\\()"
        return sources.filter { $0.text.range(of: pattern, options: .regularExpression) != nil }.map(\.name)
    }

    @Test("每個旗標至少有一支 UI 測試在用;列出沒有任何測試使用的旗標")
    func everyFlagIsUsedByAUITest() throws {
        let sources = try Self.uiTestSources()
        let unused = LaunchFlag.allCases.filter { Self.users(of: $0, in: sources).isEmpty }.map(\.rawValue)
        #expect(unused.isEmpty, "沒有任何 UI 測試使用的旗標(請刪掉,或寫用到它的 UI 測試):\(unused)")
    }

    @Test("UI 測試不手寫旗標字串,一律用 LaunchFlag(拼錯在編譯時就會被抓到)")
    func uiTestsDoNotHardcodeFlagStrings() throws {
        let known = Set(LaunchFlag.allCases.map(\.rawValue))
        for (name, text) in try Self.uiTestSources() {
            for flag in known where text.contains("\"\(flag)\"") {
                Issue.record("\(name) 手寫了旗標字串 \(flag),請改用 LaunchFlag")
            }
        }
    }

    @Test("旗標字串等於 -<案例名稱>,且不重複")
    func flagNamesFollowTheConvention() {
        let values = LaunchFlag.allCases.map(\.rawValue)
        #expect(Set(values).count == values.count)
        for flag in LaunchFlag.allCases {
            #expect(flag.rawValue == "-" + String(describing: flag), "\(flag) 的字串要等於 -<案例名稱>")
        }
    }
}
