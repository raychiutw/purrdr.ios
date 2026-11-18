import Foundation
import PurrdrCore
import Testing

/// 終端機輸入元件的診斷紀錄(實機查輸入法問題用):只記字元類別與長度，不記原文。
@Suite("終端機輸入診斷紀錄")
struct TerminalInputTraceTests {
    @Test("字元類別：注音 Z、聲調 T、漢字 H、ASCII A、其他 O")
    func characterClasses() {
        #expect(TerminalInputTrace.characterClasses("你ㄏㄠˇ ok!é") == "HZZTAAAAO")
        #expect(TerminalInputTrace.characterClasses("ˊˋ˙ㆠにほん🙂") == "TTTZOOOO")
        #expect(TerminalInputTrace.characterClasses("") == "-")
    }

    @Test("字元類別太長時只留前 40 個")
    func longTextIsTruncated() {
        #expect(TerminalInputTrace.characterClasses(String(repeating: "a", count: 50)) == String(repeating: "A", count: 40) + "…")
    }

    @Test("選字組字：記事件、UTF-16 長度、選取範圍、組字前後狀態，不含原文")
    func setMarkedTextLine() {
        let line = TerminalInputTrace.line(
            .setMarkedText, text: "ㄏㄠˇ", selectedRange: NSRange(location: 3, length: 0),
            markedBefore: "ㄏㄠ", markedAfter: "ㄏㄠˇ", sent: []
        )

        #expect(line == "setMarkedText text=3:ZZT sel=3+0 marked=2:ZZ>3:ZZT sent=none")
        #expect(!line.contains("ㄏ"))
    }

    @Test("系統結束組字送出確認的文字：記送出的位元組數，不含原文")
    func unmarkTextLine() {
        let line = TerminalInputTrace.line(
            .unmarkText, selectedRange: NSRange(location: 0, length: 0),
            markedBefore: "好", markedAfter: "", sent: [.bytes(Data("好".utf8))]
        )

        #expect(line == "unmarkText sel=0+0 marked=1:H>0:- sent=bytes:3")
        #expect(!line.contains("好"))
    }

    @Test("按鍵與貼上只記種類與長度", arguments: [
        (TerminalInputCall.keyBarKey, [TerminalRemoteInput.key(.character("x"), modifiers: [])], "keyBarKey sel=0+0 marked=2:HH>0:- sent=key"),
        (.paste, [.paste("secret")], "paste sel=0+0 marked=2:HH>0:- sent=paste:6"),
        (.resignFirstResponder, [], "resignFirstResponder sel=0+0 marked=2:HH>0:- sent=none"),
    ])
    func keyAndPasteLines(call: TerminalInputCall, sent: [TerminalRemoteInput], expected: String) {
        let line = TerminalInputTrace.line(
            call, selectedRange: NSRange(location: 0, length: 0), markedBefore: "你好", markedAfter: "", sent: sent
        )

        #expect(line == expected)
    }

    @Test("每個輸入入口(UITextInput、焦點、按鍵列、貼上)都有自己的事件名稱")
    func callNames() {
        #expect(TerminalInputCall.allCases.map(\.rawValue) == [
            "setMarkedText", "unmarkText", "insertText", "deleteBackward", "replace",
            "becomeFirstResponder", "resignFirstResponder", "cancelComposition", "keyBarKey", "paste",
        ])
    }
}
