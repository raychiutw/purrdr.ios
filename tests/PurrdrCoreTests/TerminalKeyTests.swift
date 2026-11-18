import Foundation
import PurrdrCore
import Testing

/// 終端機按鍵列送出的 bytes(行為規格 §6.4 的對照表)。
@Suite("終端機按鍵編碼")
struct TerminalKeyTests {
    static func bytes(_ key: TerminalKey, _ modifiers: TerminalModifiers = []) -> [UInt8] {
        Array(key.bytes(modifiers: modifiers))
    }

    @Test("無修飾：Esc、Tab、方向鍵(固定 CSI 形式)、Home／End、字面字元")
    func plainKeys() {
        #expect(Self.bytes(.escape) == [0x1B])
        #expect(Self.bytes(.tab) == [0x09])
        #expect(Self.bytes(.left) == [0x1B, 0x5B, 0x44])
        #expect(Self.bytes(.down) == [0x1B, 0x5B, 0x42])
        #expect(Self.bytes(.up) == [0x1B, 0x5B, 0x41])
        #expect(Self.bytes(.right) == [0x1B, 0x5B, 0x43])
        #expect(Self.bytes(.home) == [0x1B, 0x5B, 0x48])
        #expect(Self.bytes(.end) == [0x1B, 0x5B, 0x46])
        #expect(Self.bytes(.character("/")) == [0x2F])
        #expect(Self.bytes(.character("|")) == [0x7C])
        #expect(Self.bytes(.character("中")) == Array("中".utf8))
    }

    @Test("游標類鍵帶修飾變成 CSI 1;<1 + Alt 2 + Ctrl 4><final>")
    func modifiedCursorKeys() {
        #expect(Self.bytes(.up, .control) == Array("\u{1B}[1;5A".utf8))
        #expect(Self.bytes(.left, .alt) == Array("\u{1B}[1;3D".utf8))
        #expect(Self.bytes(.end, [.control, .alt]) == Array("\u{1B}[1;7F".utf8))
    }

    @Test("Esc／Tab:只有 Ctrl 送原 byte,有 Alt 前面加 ESC")
    func modifiedEscapeAndTab() {
        #expect(Self.bytes(.escape, .control) == [0x1B])
        #expect(Self.bytes(.tab, .alt) == [0x1B, 0x09])
    }

    @Test("字元加 Ctrl:字母 → 0x01–0x1A,符號依對照表，其他不變;Alt 在前面加 ESC", arguments: [
        ("c", [0x03]), ("C", [0x03]), ("a", [0x01]), ("z", [0x1A]),
        ("@", [0x00]), (" ", [0x00]), ("2", [0x00]),
        ("[", [0x1B]), ("3", [0x1B]),
        ("\\", [0x1C]), ("|", [0x1C]), ("4", [0x1C]),
        ("]", [0x1D]), ("5", [0x1D]),
        ("^", [0x1E]), ("~", [0x1E]), ("6", [0x1E]),
        ("_", [0x1F]), ("-", [0x1F]), ("/", [0x1F]), ("7", [0x1F]),
        ("?", [0x7F]), ("8", [0x7F]),
        ("=", [0x3D]),
    ] as [(Character, [UInt8])])
    func controlCharacters(character: Character, expected: [UInt8]) {
        #expect(Self.bytes(.character(character), .control) == expected)
    }

    @Test("Ctrl + Alt + 字元 = ESC + 控制字元")
    func controlAltCharacter() {
        #expect(Self.bytes(.character("x"), [.control, .alt]) == [0x1B, 0x18])
        #expect(Self.bytes(.character("b"), .alt) == [0x1B, 0x62])
    }

    @Test("實體鍵盤：Page Up／Down、Delete、F1–F12(xterm 編碼)")
    func hardwareOnlyKeys() {
        #expect(Self.bytes(.pageUp) == Array("\u{1B}[5~".utf8))
        #expect(Self.bytes(.pageDown) == Array("\u{1B}[6~".utf8))
        #expect(Self.bytes(.deleteForward) == Array("\u{1B}[3~".utf8))
        #expect(Self.bytes(.function(1)) == Array("\u{1B}OP".utf8))
        #expect(Self.bytes(.function(4)) == Array("\u{1B}OS".utf8))
        #expect(Self.bytes(.function(5)) == Array("\u{1B}[15~".utf8))
        #expect(Self.bytes(.function(10)) == Array("\u{1B}[21~".utf8))
        #expect(Self.bytes(.function(11)) == Array("\u{1B}[23~".utf8))
        #expect(Self.bytes(.function(12)) == Array("\u{1B}[24~".utf8))
        #expect(Self.bytes(.function(13)).isEmpty)
    }

    @Test("實體鍵盤的修飾參數含 Shift(1 + Shift 1 + Alt 2 + Ctrl 4);Shift-Tab 是 CSI Z")
    func shiftModifiedKeys() {
        #expect(Self.bytes(.up, .shift) == Array("\u{1B}[1;2A".utf8))
        #expect(Self.bytes(.left, [.shift, .control]) == Array("\u{1B}[1;6D".utf8))
        #expect(Self.bytes(.pageUp, .control) == Array("\u{1B}[5;5~".utf8))
        #expect(Self.bytes(.function(2), .shift) == Array("\u{1B}[1;2Q".utf8))
        #expect(Self.bytes(.function(5), .alt) == Array("\u{1B}[15;3~".utf8))
        #expect(Self.bytes(.tab, .shift) == Array("\u{1B}[Z".utf8))
        #expect(Self.bytes(.escape, .shift) == [0x1B])
        #expect(Self.bytes(.character("A"), .shift) == [0x41])
    }
}
