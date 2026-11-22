import Foundation
import Testing

/// Plus 頁功能列的圖示(#323,使用者決定):app 主色(tint)的線條圖示——outline SF Symbol、不填色、沒有彩色圓角底。
/// 畫面原始碼掃描守門。
@Suite("Plus 功能列圖示")
struct PlusFeatureIconUsageTests {
    static func source(_ name: String) -> String {
        let file = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures/\(name)")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    @Test("功能的圖示都是線條(不用 .fill)，也不再有每項功能的顏色")
    func featureSymbolsAreOutlines() throws {
        let features = Self.source("PlusFeatures.swift")
        try #require(!features.isEmpty, "找不到 PlusFeatures.swift")
        let symbols = features.split(separator: "\n").filter { $0.contains(": \"") && $0.contains("case .") && !$0.contains("title") }
        #expect(!features.contains(".fill\""), "PlusFeatures.swift 的圖示不要填色(.fill)")
        #expect(!features.contains("var color"), "PlusFeature 不再有 color")
        #expect(!symbols.isEmpty)
    }

    @Test("功能列的圖示用主色線條,沒有彩色圓角底")
    func rowIconIsTintedWithoutBackground() throws {
        let view = Self.source("PlusView.swift")
        try #require(!view.isEmpty, "找不到 PlusView.swift")
        #expect(!view.contains("color: feature.color") && !view.contains("color: .gray"), "功能列不再傳彩色")
        #expect(!view.contains(".background(color, in: RoundedRectangle"), "圖示不要彩色圓角底")
        #expect(!view.contains("terminal.fill"), "免費那列也用線條圖示")
    }
}
