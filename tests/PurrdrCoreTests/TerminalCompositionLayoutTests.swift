import PurrdrCore
import Testing

/// 組字浮層的版面(#140):畫在遠端游標格子上，寬字元佔兩格，選字窗跟著組字位置。
@Suite("終端機組字浮層版面")
struct TerminalCompositionLayoutTests {
    typealias Box = TerminalCompositionLayout.Box

    /// 游標在第 10 欄、第 3 列;格子 8×17,畫面寬 80 欄。
    static let cursor = Box(x: 80, y: 51, width: 8, height: 17)
    static let screenWidth = 640.0

    static func layout(_ markedText: String, cursor: Box = cursor) -> TerminalCompositionLayout {
        TerminalCompositionLayout(markedText: markedText, cursor: cursor, cellWidth: 8, screenWidth: screenWidth)
    }

    @Test("欄寬：注音與中文佔兩格，聲調、英文佔一格，組合字元不另佔格")
    func columnWidths() {
        #expect(TerminalCompositionLayout.columns(of: "ni") == 2)
        #expect(TerminalCompositionLayout.columns(of: "ㄋㄧˇ") == 5)
        #expect(TerminalCompositionLayout.columns(of: "你好") == 4)
        #expect(TerminalCompositionLayout.columns(of: "にほん") == 6)
        #expect(TerminalCompositionLayout.columns(of: "한") == 2)
        #expect(TerminalCompositionLayout.columns(of: "😀") == 2)
        #expect(TerminalCompositionLayout.columns(of: "e\u{301}") == 1)
        #expect(TerminalCompositionLayout.columns(of: "") == 0)
    }

    @Test("欄寬：emoji 組合序列(ZWJ、膚色、國旗、keycap)佔兩格", arguments: [
        "👨\u{200D}👩\u{200D}👧", "👍🏽", "🇹🇼", "1\u{FE0F}\u{20E3}", "❤\u{FE0F}", "⌚",
    ])
    func emojiSequencesAreTwoColumns(text: String) {
        #expect(TerminalCompositionLayout.columns(of: text) == 2)
    }

    @Test("欄寬：變體選擇符同 SwiftTerm——VS15(文字樣式)一格，VS16 只讓 emoji 基底變兩格", arguments: [
        ("⌚\u{FE0E}", 1),
        ("☺\u{FE0E}", 1),
        ("☺", 1),
        ("a\u{FE0F}", 1),
        ("中\u{FE0E}", 2),
    ])
    func variationSelectors(text: String, columns: Int) {
        #expect(TerminalCompositionLayout.columns(of: text) == columns)
    }

    @Test("欄寬：全形標點兩格，半形片假名與一般標點一格", arguments: [
        ("，", 2), ("。", 2), ("、", 2), ("「", 2), ("」", 2), ("！", 2), ("？", 2), ("：", 2), ("（", 2), ("～", 2),
        ("ｱ", 1), ("—", 1), ("…", 1), (",", 1),
    ])
    func fullwidthPunctuation(text: String, columns: Int) {
        #expect(TerminalCompositionLayout.columns(of: text) == columns)
    }

    @Test("浮層從游標格子開始，寬度是組字文字的格數")
    func overlayStartsAtCursorCell() {
        #expect(Self.layout("ㄋㄧˇ").overlay == Box(x: 80, y: 51, width: 40, height: 17))
        #expect(Self.layout("ni").overlay == Box(x: 80, y: 51, width: 16, height: 17))
    }

    @Test("游標移動後浮層跟著移")
    func overlayFollowsCursor() {
        let moved = Self.layout("你", cursor: Box(x: 0, y: 68, width: 8, height: 17))
        #expect(moved.overlay == Box(x: 0, y: 68, width: 16, height: 17))
    }

    @Test("游標靠右邊，浮層超出畫面時往左移，整段留在畫面內")
    func overlayShiftsLeftAtRightEdge() {
        let nearEdge = Box(x: 624, y: 51, width: 8, height: 17)
        #expect(Self.layout("你好", cursor: nearEdge).overlay == Box(x: 608, y: 51, width: 32, height: 17))
    }

    @Test("組字文字比畫面寬時，浮層從畫面左緣開始")
    func overlayWiderThanScreenStartsAtLeftEdge() {
        let long = String(repeating: "你", count: 50)
        #expect(Self.layout(long).overlay == Box(x: 0, y: 51, width: 800, height: 17))
    }

    @Test("沒有組字時，選字窗與插入點的矩形就是游標格子")
    func emptyCompositionUsesCursorCell() {
        let empty = Self.layout("")
        #expect(empty.rect(utf16Location: 0, length: 0) == Box(x: 80, y: 51, width: 8, height: 17))
        #expect(empty.caret(utf16Offset: 0) == Box(x: 80, y: 51, width: 2, height: 17))
    }

    @Test("組字段的矩形依格數換算(UTF-16 位置)")
    func rectForMarkedRange() {
        let zhuyin = Self.layout("你ㄏㄠˇ")
        // 整段：2 + 2 + 2 + 1 = 7 格。
        #expect(zhuyin.rect(utf16Location: 0, length: 4) == Box(x: 80, y: 51, width: 56, height: 17))
        // 「ㄏㄠˇ」:從第 2 格開始、5 格。
        #expect(zhuyin.rect(utf16Location: 1, length: 3) == Box(x: 96, y: 51, width: 40, height: 17))
        // 空範圍給一格寬，選字窗才有位置可以對齊。
        #expect(zhuyin.rect(utf16Location: 4, length: 0) == Box(x: 136, y: 51, width: 8, height: 17))
    }

    @Test("插入點在組字文字裡的位置;emoji 的 UTF-16 長度是 2")
    func caretInsideMarkedText() {
        #expect(Self.layout("ni").caret(utf16Offset: 1) == Box(x: 88, y: 51, width: 2, height: 17))
        #expect(Self.layout("😀a").caret(utf16Offset: 2) == Box(x: 96, y: 51, width: 2, height: 17))
        // 超出範圍時夾在結尾。
        #expect(Self.layout("ni").caret(utf16Offset: 9) == Box(x: 96, y: 51, width: 2, height: 17))
    }

    @Test("浮層往左移時，組字段矩形跟著浮層")
    func rectFollowsShiftedOverlay() {
        let nearEdge = Box(x: 624, y: 51, width: 8, height: 17)
        let shifted = Self.layout("你好", cursor: nearEdge)
        #expect(shifted.rect(utf16Location: 1, length: 1) == Box(x: 624, y: 51, width: 16, height: 17))
        #expect(shifted.caret(utf16Offset: 2) == Box(x: 640, y: 51, width: 2, height: 17))
    }

    @Test("xterm 256 色：16–231 是 6×6×6 色塊、232–255 是灰階")
    func xtermPalette() {
        #expect(TerminalCompositionLayout.xterm256(16) == TerminalCompositionLayout.RGB(red: 0, green: 0, blue: 0))
        #expect(TerminalCompositionLayout.xterm256(21) == TerminalCompositionLayout.RGB(red: 0, green: 0, blue: 255))
        #expect(TerminalCompositionLayout.xterm256(196) == TerminalCompositionLayout.RGB(red: 255, green: 0, blue: 0))
        #expect(TerminalCompositionLayout.xterm256(110) == TerminalCompositionLayout.RGB(red: 135, green: 175, blue: 215))
        #expect(TerminalCompositionLayout.xterm256(232) == TerminalCompositionLayout.RGB(red: 8, green: 8, blue: 8))
        #expect(TerminalCompositionLayout.xterm256(255) == TerminalCompositionLayout.RGB(red: 238, green: 238, blue: 238))
        // 0–15 由主題決定，這裡不給。
        #expect(TerminalCompositionLayout.xterm256(15) == nil)
    }
}
