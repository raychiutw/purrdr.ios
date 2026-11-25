import Foundation
import Testing

/// 不能點的狀態文字不用主色(#639、spec #634):主色代表可以點的東西,狀態文字用主色會像按鈕。
@Suite("狀態文字顏色用法")
struct StatusTextColorUsageTests {
    @Test("Plus「使用中」不用主色(.tint)")
    func plusInUseIsNotAccent() throws {
        let plus = try #require(try ListButtonScanner.sourceFiles().first { $0.name == "PlusView.swift" })
        let index = try #require(plus.lines.firstIndex { $0.contains("Text(\"In Use\")") })
        let modifiers = plus.lines[index ... index + 3].joined(separator: "\n")
        #expect(!modifiers.contains(".tint"), "「使用中」是不能點的狀態,不要用主色:\n\(modifiers)")
        #expect(!modifiers.contains("accentColor") && !modifiers.contains("Color.accent"))
    }
}
