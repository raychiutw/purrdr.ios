import Foundation
import Testing

/// DESIGN.md「狀態色」:顏色只上符號與圓點,文字不上橙／紅。context 百分比文字維持一般文字色，只讓圓環與進度條變色;
/// 顏色的對應只在 `ContextLevel.tint` 一處(不在畫面裡重複寫巢狀三元式)。畫面原始碼掃描守門。
@Suite("context 用量的顏色")
struct ContextMeterColorUsageTests {
    static let source: String = {
        let file = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures/AgentProgressViews.swift")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }()

    @Test("百分比文字不套用等級顏色")
    func percentTextIsNotTinted() throws {
        try #require(!Self.source.isEmpty, "找不到 AgentProgressViews.swift")
        let lines = Self.source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated()
        where line.contains("foregroundStyle") && (line.contains("level.") || line.contains("contextLevel")) {
            Issue.record("AgentProgressViews.swift:\(index + 1) 文字不上橙／紅:\(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    @Test("等級顏色只在 ContextLevel.tint 一處,畫面不重複寫三元式")
    func tintIsDefinedOnce() throws {
        try #require(!Self.source.isEmpty, "找不到 AgentProgressViews.swift")
        #expect(!Self.source.contains("Color.orange : Color.red"), "畫面裡重複寫了顏色三元式")
        #expect(Self.source.contains("var tint"), "ContextLevel 要提供單一 tint")
    }
}
