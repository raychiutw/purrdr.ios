import Foundation
@testable import PurrdrAgentFeatures
import Testing

/// 輸入框與聊天裡開頭的 skill／slash 指令(實機回報 2026-11-20:要用系統綠色標出)。
@Suite("開頭的 slash 指令")
struct SlashTokenTests {
    @Test("開頭的「/名稱」(到第一個空白為止)")
    func leadingToken() {
        let text = "/tdd fix the CSV quoting"
        let range = SlashToken.range(in: text)
        #expect(range.map { String(text[$0]) } == "/tdd")
        #expect(SlashToken.range(in: "/demo-kit:changelog").map { String("/demo-kit:changelog"[$0]) } == "/demo-kit:changelog")
    }

    @Test("不是開頭、只有斜線、路徑都不算")
    func notTokens() {
        #expect(SlashToken.range(in: "run /tdd") == nil)
        #expect(SlashToken.range(in: "/") == nil)
        #expect(SlashToken.range(in: "/ hello") == nil)
        #expect(SlashToken.range(in: "/Users/demo/ledger") == nil, "主機路徑不是指令")
        #expect(SlashToken.range(in: "") == nil)
    }
}
