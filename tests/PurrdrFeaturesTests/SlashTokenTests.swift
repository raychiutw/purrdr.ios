import Foundation
@testable import PurrdrAgentFeatures
@testable import PurrdrFeatures
import SwiftUI
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

/// 訊息中間接在空白之後的指令(#469):只有在已知名稱裡才上色，路徑與一般文字不誤上色。
@Suite("文中的 slash 指令")
struct InlineSlashTokenTests {
    private func found(_ text: String, known: Set<String>) -> [String] {
        SlashToken.ranges(in: text, known: known).map { String(text[$0]) }
    }

    @Test("開頭一律算，文中已知名稱才算，多個都算")
    func leadingAndKnownInline() {
        #expect(found("/tdd fix with /grill and /to-spec", known: ["grill", "to-spec"]) == ["/tdd", "/grill", "/to-spec"])
        #expect(found("先用 /grill 再說", known: ["grill"]) == ["/grill"])
        #expect(found("/tdd 開頭在清單還沒載入時照舊上色", known: []) == ["/tdd"])
    }

    @Test("文中未知名稱、路徑、網址、a/b、名稱含斜線都不算")
    func notInline() {
        let known: Set<String> = ["tmp", "grill"]
        #expect(found("see /unknown here", known: known) == [])
        #expect(found("cat /tmp/x and /usr/bin/env", known: ["usr", "tmp"]) == [])
        #expect(found("open https://example.com/grill", known: known) == [])
        #expect(found("a/grill b/tmp", known: known) == [])
        #expect(found("check /Users/demo/ledger", known: ["Users"]) == [])
        #expect(found("x /", known: known) == [])
    }

    @Test("文中名稱到空白或結尾為止")
    func endsAtWhitespace() {
        #expect(found("run /grill", known: ["grill"]) == ["/grill"])
        #expect(found("run /grill, ok", known: ["grill"]) == [])
        #expect(found("run /grill\nnext /grill", known: ["grill"]) == ["/grill", "/grill"])
    }

    @Test("中英文混排與 emoji 的範圍正確(UTF-16 轉換)")
    func utf16Ranges() {
        let text = "😀你好 /grill 與 /to-spec 😀"
        let ranges = SlashToken.ranges(in: text, known: ["grill", "to-spec"])
        let ns = ranges.map { NSRange($0, in: text) }
        #expect(ns.map { (text as NSString).substring(with: $0) } == ["/grill", "/to-spec"])
    }
}

/// 使用者泡泡的著色(#469):與輸入框同一套規則。
@Suite("使用者泡泡的 slash 指令上色")
struct UserBubbleSlashTests {
    private func colored(_ text: String, known: Set<String>) -> [String] {
        let attributed = UserBubbleView.highlighted(text, known: known)
        return attributed.runs.filter { $0.foregroundColor != nil }.map { String(attributed[$0.range].characters) }
    }

    @Test("開頭與文中已知指令上色，路徑不上色")
    func bubble() {
        #expect(colored("/tdd 然後 /grill 看 /tmp/x", known: ["grill", "tmp"]) == ["/tdd", "/grill"])
        #expect(colored("先 /grill", known: []) == [])
    }
}
