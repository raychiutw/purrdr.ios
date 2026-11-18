import Foundation
import PurrdrCore
import Testing

/// 終端機接管鍵盤輸入後的組字規則(#136):組字期間不送任何東西，確認後才送出。
@Suite("終端機組字狀態")
struct TerminalCompositionTests {
    static func text(_ string: String) -> [TerminalInputSend] {
        [.bytes(Data(string.utf8))]
    }

    static let backspace: [TerminalInputSend] = [.bytes(Data([0x7F]))]

    @Test("注音組字到選字確認：組字中不送，確認後只送確認的文字")
    func zhuyinCommitSendsOnlyConfirmedText() {
        var composition = TerminalComposition()

        composition.setMarkedText("ㄋ")
        composition.setMarkedText("ㄋㄧ")
        composition.setMarkedText("ㄋㄧˇ")
        #expect(composition.isComposing)
        #expect(composition.markedText == "ㄋㄧˇ")

        #expect(composition.insertText("你") == Self.text("你"))
        #expect(!composition.isComposing)
        #expect(composition.markedText == "")
    }

    @Test("組字中刪字只改組字文字，不送退格;刪光就結束組字")
    func deletingWhileComposingSendsNothing() {
        var composition = TerminalComposition()
        composition.setMarkedText("ㄋㄧˇ")

        #expect(composition.deleteBackward() == [])
        #expect(composition.markedText == "ㄋㄧ")
        #expect(composition.deleteBackward() == [])
        #expect(composition.deleteBackward() == [])
        #expect(!composition.isComposing)
        // 組字結束後的刪除才送到遠端。
        #expect(composition.deleteBackward() == Self.backspace)
    }

    @Test("輸入法把組字文字設成空字串(取消組字)時不送")
    func clearingMarkedTextSendsNothing() {
        var composition = TerminalComposition()
        composition.setMarkedText("ni")

        composition.setMarkedText("")

        #expect(!composition.isComposing)
        #expect(composition.unmarkText() == [])
    }

    @Test("Purrdr 自己結束組字(切換焦點、點畫面、換字型)放棄組字文字，之後系統的結束組字也不送")
    func cancelDropsMarkedText() {
        var composition = TerminalComposition()
        composition.setMarkedText("ㄋㄧˇ")

        composition.cancel()

        #expect(!composition.isComposing)
        #expect(composition.unmarkText() == [])
        #expect(composition.insertText("a") == Self.text("a"))
    }

    @Test("系統在組字中結束組字：送出輸入法最後給的文字(已選好的字)")
    func systemUnmarkCommitsConvertedText() {
        var composition = TerminalComposition()
        composition.setMarkedText("にほん")
        composition.setMarkedText("日本")

        #expect(composition.unmarkText() == Self.text("日本"))
        #expect(!composition.isComposing)
    }

    @Test("系統在組字中結束組字：注音符號與聲調本身不送，只送已轉好的字")
    func systemUnmarkDropsZhuyinSymbols() {
        var composition = TerminalComposition()
        composition.setMarkedText("ㄋㄧˇ")
        #expect(composition.unmarkText() == [])
        #expect(!composition.isComposing)

        composition.setMarkedText("你ㄏㄠˇ")
        #expect(composition.unmarkText() == Self.text("你"))

        composition.setMarkedText("ㄅㄆㄇㄈˊˋ˙ㆠ")
        #expect(composition.unmarkText() == [])
    }

    @Test("沒有組字時：英文逐字送出、刪除送 DEL、Return 送 CR")
    func plainInputWithoutComposition() {
        var composition = TerminalComposition()

        #expect(composition.insertText("l") == Self.text("l"))
        #expect(composition.insertText("s") == Self.text("s"))
        #expect(composition.deleteBackward() == Self.backspace)
        #expect(composition.insertText("\n") == Self.text("\r"))
        // 聽寫一次給多行時，每個換行都變成 CR。
        #expect(composition.insertText("echo hi\nls\r\n") == Self.text("echo hi\rls\r"))
        #expect(composition.unmarkText() == [])
        #expect(!composition.isComposing)
    }

    @Test("emoji 與寬字元照 UTF-8 送出;在組字中也一樣只送確認的文字")
    func emojiAndWideCharacters() {
        var composition = TerminalComposition()

        #expect(composition.insertText("👍🏽") == Self.text("👍🏽"))
        #expect(composition.insertText("👨‍👩‍👧") == Self.text("👨‍👩‍👧"))
        #expect(composition.insertText("中文") == [.bytes(Data([0xE4, 0xB8, 0xAD, 0xE6, 0x96, 0x87]))])

        composition.setMarkedText("ㄏㄠˇ")
        #expect(composition.insertText("好😀") == Self.text("好😀"))
    }

    @Test("組字中刪字以字元(grapheme)為單位，不會切壞 emoji 或寬字元")
    func deletingWhileComposingRemovesWholeCharacters() {
        var composition = TerminalComposition()
        composition.setMarkedText("日本👍🏽")

        #expect(composition.deleteBackward() == [])
        #expect(composition.markedText == "日本")
    }

    // MARK: - 實體鍵盤

    @Test("沒有組字時，特殊鍵帶實體修飾鍵經 press 送出", arguments: [
        (TerminalHardwareKey.escape, TerminalModifiers(), TerminalKey.escape),
        (.tab, [], .tab),
        (.tab, .shift, .tab),
        (.up, [], .up),
        (.down, .control, .down),
        (.left, .alt, .left),
        (.right, .shift, .right),
        (.home, [], .home),
        (.end, [], .end),
        (.pageUp, [], .pageUp),
        (.pageDown, .shift, .pageDown),
        (.deleteForward, [], .deleteForward),
        (.function(1), [], .function(1)),
        (.function(12), .control, .function(12)),
        (.character("c"), .control, .character("c")),
        (.character("b"), .alt, .character("b")),
        (.character("x"), [.control, .alt], .character("x")),
    ] as [(TerminalHardwareKey, TerminalModifiers, TerminalKey)])
    func specialKeysAreSent(key: TerminalHardwareKey, modifiers: TerminalModifiers, expected: TerminalKey) {
        let composition = TerminalComposition()

        #expect(composition.handle(key, modifiers: modifiers) == .send(.key(expected, modifiers: modifiers)))
    }

    @Test("沒有組字時，一般字元、Return、刪除交給系統文字輸入(輸入法才看得到第一個鍵)", arguments: [
        (TerminalHardwareKey.character("a"), TerminalModifiers()),
        (.character("A"), .shift),
        (.character("ㄅ"), []),
        (.returnKey, []),
        (.returnKey, .shift),
        (.deleteBackward, []),
    ] as [(TerminalHardwareKey, TerminalModifiers)])
    func plainKeysGoToSystem(key: TerminalHardwareKey, modifiers: TerminalModifiers) {
        let composition = TerminalComposition()

        #expect(composition.handle(key, modifiers: modifiers) == .system)
    }

    @Test("Alt + Return／刪除送 ESC 前綴(Meta)")
    func altReturnAndDelete() {
        let composition = TerminalComposition()

        #expect(composition.handle(.returnKey, modifiers: .alt) == .send(.bytes(Data([0x1B, 0x0D]))))
        #expect(composition.handle(.deleteBackward, modifiers: .alt) == .send(.bytes(Data([0x1B, 0x7F]))))
    }

    @Test("組字中所有實體鍵(含 Ctrl-C、Esc、Return、方向鍵)都交給輸入法", arguments: [
        (TerminalHardwareKey.character("c"), TerminalModifiers.control),
        (.escape, []),
        (.returnKey, []),
        (.left, []),
        (.character(" "), []),
        (.deleteBackward, .alt),
    ] as [(TerminalHardwareKey, TerminalModifiers)])
    func keysWhileComposingGoToInputMethod(key: TerminalHardwareKey, modifiers: TerminalModifiers) {
        var composition = TerminalComposition()
        composition.setMarkedText("ㄋㄧ")

        #expect(composition.handle(key, modifiers: modifiers) == .system)
    }
}
