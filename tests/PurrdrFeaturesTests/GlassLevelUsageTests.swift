import Foundation
import Testing

/// 玻璃層級(#425,DESIGN.md「Liquid Glass」):部分高度的 sheet 讓系統自動套玻璃,所以 sheet 內的清單不鋪不透明的頁面底
/// (`appSheetList()`,只設列底);浮在內容上的跳到最新鈕與離線橫幅走 `floatingGlass`,減少透明度時不透明。
@Suite("玻璃層級用法")
struct GlassLevelUsageTests {
    static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    static func source(_ name: String) throws -> String {
        try String(contentsOf: featuresFolder.appending(path: name), encoding: .utf8)
    }

    @Test("模型、effort 與新增聊天 sheet 的清單不鋪不透明頁面底(讓系統玻璃透出)")
    func partialSheetsKeepSystemGlass() throws {
        for name in ["ModelCapsule.swift", "NewChatView.swift"] {
            let text = try Self.source(name)
            #expect(!text.contains(".appGroupedList()"), "\(name) 的 sheet 清單改用 appSheetList()")
            #expect(text.contains(".appSheetList()"), "\(name) 找不到 appSheetList()")
        }
    }

    @Test("新增聊天 sheet 是部分高度")
    func newChatIsPartialHeight() throws {
        #expect(try Self.source("TopNavigationView.swift").contains("NewChatSheet"))
        #expect(try Self.source("NewChatView.swift").contains("presentationDetents([.medium, .large])"))
    }

    @Test("跳到最新鈕走 floatingGlass(減少透明度時不透明),不直接用 .glass 按鈕樣式")
    func jumpToLatestUsesFloatingGlass() throws {
        let text = try Self.source("ConversationView.swift")
        let start = try #require(text.range(of: "Jump to Latest"))
        let window = String(text[start.lowerBound...].prefix(500))
        #expect(window.contains("floatingGlass"))
        #expect(!window.contains(".buttonStyle(.glass)"))
    }
}
