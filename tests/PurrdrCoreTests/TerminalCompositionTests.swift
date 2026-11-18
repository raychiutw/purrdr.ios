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

    /// 登入 Shell:遠端程式開了 alternate screen(less、vim)。
    static let fullScreen = TerminalProgramModes.visible(applicationCursor: false, alternateScreen: true)
    /// 登入 Shell:一般畫面。
    static let normalScreen = TerminalProgramModes.visible(applicationCursor: false, alternateScreen: false)

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

    @Test("系統發起的結束組字一律放棄組字文字、不送出(拼音、日文假名、注音都一樣)", arguments: [
        ["ni hao"],
        ["にほん"],
        ["にほん", "日本"],
        ["你ㄏㄠˇ"],
        ["ㄅㄆㄇㄈˊˋ˙ㆠ"],
    ])
    func systemUnmarkDiscardsMarkedText(markedTexts: [String]) {
        var composition = TerminalComposition()
        markedTexts.forEach { composition.setMarkedText($0) }

        #expect(composition.unmarkText() == [])
        #expect(!composition.isComposing)
        #expect(composition.markedText == "")
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

        #expect(composition.handle(key, modifiers: modifiers, modes: Self.fullScreen) == .send(.key(expected, modifiers: modifiers)))
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

        #expect(composition.handle(key, modifiers: modifiers, modes: Self.fullScreen) == .system)
    }

    @Test("Alt + Return／刪除送 ESC 前綴(Meta)")
    func altReturnAndDelete() {
        let composition = TerminalComposition()

        #expect(composition.handle(.returnKey, modifiers: .alt, modes: Self.fullScreen) == .send(.bytes(Data([0x1B, 0x0D]))))
        #expect(composition.handle(.deleteBackward, modifiers: .alt, modes: Self.fullScreen) == .send(.bytes(Data([0x1B, 0x7F]))))
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

        #expect(composition.handle(key, modifiers: modifiers, modes: Self.fullScreen) == .system)
    }

    @Test("組字中其他實體鍵(方向鍵、Tab、Page、功能鍵、Ctrl／Alt 組合)也都交給輸入法，不送遠端", arguments: [
        (TerminalHardwareKey.up, TerminalModifiers()),
        (.down, []),
        (.right, .shift),
        (.tab, []),
        (.pageUp, []),
        (.pageDown, []),
        (.home, []),
        (.deleteForward, []),
        (.function(5), []),
        (.character("d"), .control),
        (.character("b"), .alt),
        (.returnKey, .alt),
    ] as [(TerminalHardwareKey, TerminalModifiers)])
    func moreKeysWhileComposingGoToInputMethod(key: TerminalHardwareKey, modifiers: TerminalModifiers) {
        var composition = TerminalComposition()
        composition.setMarkedText("ㄏㄠ")

        #expect(composition.handle(key, modifiers: modifiers, modes: Self.fullScreen) == .system)
        #expect(composition.handle(key, modifiers: modifiers, modes: Self.normalScreen) == .system)
        #expect(composition.handle(key, modifiers: modifiers, modes: .hiddenByHerdr) == .system)
    }

    // MARK: - 按鍵列與貼上(#141)

    @Test("組字中按按鍵列：放棄組字(不送出)，只送該鍵", arguments: [
        TerminalKey.escape, .tab, .up, .home, .character("/"), .character("~"),
    ])
    func keyBarWhileComposingDropsMarkedText(key: TerminalKey) {
        var composition = TerminalComposition()
        composition.setMarkedText("ㄋㄧˇ")

        #expect(composition.pressKeyBarKey(key, modes: .hiddenByHerdr) == [.key(key, modifiers: [])])
        #expect(!composition.isComposing)
        #expect(composition.markedText == "")
        // 系統隨後結束組字也不會把注音送出。
        #expect(composition.unmarkText() == [])
    }

    @Test("沒有組字時按按鍵列：照常送該鍵")
    func keyBarWithoutComposition() {
        var composition = TerminalComposition()

        #expect(composition.pressKeyBarKey(.escape, modes: .hiddenByHerdr) == [.key(.escape, modifiers: [])])
        #expect(composition.insertText("a") == Self.text("a"))
    }

    @Test("組字中貼上：放棄組字(不送出)，只送貼上內容")
    func pasteWhileComposingDropsMarkedText() {
        var composition = TerminalComposition()
        composition.setMarkedText("你ㄏㄠˇ")

        #expect(composition.paste("git status") == [.paste("git status")])
        #expect(!composition.isComposing)
        #expect(composition.unmarkText() == [])
    }

    @Test("沒有組字時貼上照常送出;剪貼簿是空的就什麼都不送，但組字一樣放棄")
    func pasteWithoutCompositionAndEmptyPaste() {
        var composition = TerminalComposition()
        #expect(composition.paste("ls -la\n") == [.paste("ls -la\n")])

        composition.setMarkedText("ㄋㄧ")
        #expect(composition.paste("") == [])
        #expect(!composition.isComposing)
    }

    // MARK: - Page Up／Down

    @Test("一般畫面(遠端沒開 alternate screen 或 application cursor)Page Up／Down 在本機捲一頁，不送遠端", arguments: [
        (TerminalHardwareKey.pageUp, TerminalModifiers(), TerminalInput.ScrollDirection.up),
        (.pageDown, [], .down),
        (.pageUp, .shift, .up),
    ] as [(TerminalHardwareKey, TerminalModifiers, TerminalInput.ScrollDirection)])
    func pageKeysScrollLocallyOnNormalScreen(key: TerminalHardwareKey, modifiers: TerminalModifiers,
                                             expected: TerminalInput.ScrollDirection) {
        let composition = TerminalComposition()

        #expect(composition.handle(key, modifiers: modifiers, modes: Self.normalScreen) == .scrollPage(expected))
    }

    @Test("遠端程式要 Page 鍵(alternate screen、application cursor)時照常送出")
    func pageKeysSentWhenRemoteWantsThem() {
        let composition = TerminalComposition()

        #expect(composition.handle(.pageUp, modifiers: [], modes: Self.fullScreen) == .send(.key(.pageUp, modifiers: [])))
        #expect(composition.handle(.pageDown, modifiers: [], modes: Self.fullScreen) == .send(.key(.pageDown, modifiers: [])))
    }

    @Test("Pane 終端機(herdr 不轉送模式):Page 鍵一律交給 herdr 依 Pane 狀態決定", arguments: [
        (TerminalHardwareKey.pageUp, TerminalModifiers(), TerminalInput.ScrollDirection.up),
        (.pageDown, [], .down),
        (.pageUp, .shift, .up),
    ] as [(TerminalHardwareKey, TerminalModifiers, TerminalInput.ScrollDirection)])
    func pageKeysGoToHerdrOnPaneTerminal(key: TerminalHardwareKey, modifiers: TerminalModifiers,
                                         expected: TerminalInput.ScrollDirection) {
        let composition = TerminalComposition()

        #expect(composition.handle(key, modifiers: modifiers, modes: .hiddenByHerdr) == .sendPageKeyToHerdr(expected))
    }

    @Test("登入 Shell 依模擬器看到的模式：一般畫面本機捲一頁，alternate screen 或 application cursor 送遠端")
    func pageKeysOnLoginShellFollowVisibleModes() {
        let composition = TerminalComposition()

        #expect(composition.handle(.pageUp, modifiers: [], modes: .visible(applicationCursor: false, alternateScreen: false))
            == .scrollPage(.up))
        #expect(composition.handle(.pageDown, modifiers: [], modes: .visible(applicationCursor: false, alternateScreen: true))
            == .send(.key(.pageDown, modifiers: [])))
        #expect(composition.handle(.pageUp, modifiers: [], modes: .visible(applicationCursor: true, alternateScreen: false))
            == .send(.key(.pageUp, modifiers: [], applicationCursor: true)))
    }

    @Test("方向鍵、Home／End 帶著遠端的 application cursor 模式;Pane 終端機看不到模式，一律 CSI", arguments: [
        (TerminalHardwareKey.up, TerminalKey.up), (.down, .down), (.left, .left), (.right, .right), (.home, .home), (.end, .end),
    ] as [(TerminalHardwareKey, TerminalKey)])
    func cursorKeysCarryApplicationCursorMode(key: TerminalHardwareKey, terminalKey: TerminalKey) {
        let composition = TerminalComposition()

        #expect(composition.handle(key, modifiers: [], modes: .visible(applicationCursor: true, alternateScreen: true))
            == .send(.key(terminalKey, modifiers: [], applicationCursor: true)))
        #expect(composition.handle(key, modifiers: [], modes: .visible(applicationCursor: false, alternateScreen: true))
            == .send(.key(terminalKey, modifiers: [], applicationCursor: false)))
        #expect(composition.handle(key, modifiers: [], modes: .hiddenByHerdr)
            == .send(.key(terminalKey, modifiers: [], applicationCursor: false)))
    }

    @Test("按鍵列的方向鍵也帶著 application cursor 模式")
    func keyBarCursorKeysCarryApplicationCursorMode() {
        var composition = TerminalComposition()

        #expect(composition.pressKeyBarKey(.up, modes: .visible(applicationCursor: true, alternateScreen: false))
            == [.key(.up, modifiers: [], applicationCursor: true)])
        #expect(composition.pressKeyBarKey(.home, modes: .hiddenByHerdr) == [.key(.home, modifiers: [], applicationCursor: false)])
    }

    @Test("Page 鍵本機捲動只影響 Page 鍵，其他特殊鍵照常送出")
    func localPageScrollDoesNotAffectOtherKeys() {
        let composition = TerminalComposition()

        #expect(composition.handle(.up, modifiers: [], modes: Self.normalScreen) == .send(.key(.up, modifiers: [])))
        #expect(composition.handle(.end, modifiers: [], modes: Self.normalScreen) == .send(.key(.end, modifiers: [])))
    }
}
