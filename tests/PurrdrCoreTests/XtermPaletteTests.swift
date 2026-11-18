import PurrdrCore
import Testing

@Suite("xterm 256 色")
struct XtermPaletteTests {
    typealias RGB = XtermPalette.RGB

    @Test("16–231 是 6×6×6 色塊、232–255 是灰階;0–15 由主題決定")
    func fixedColors() {
        #expect(XtermPalette.color(16) == RGB(red: 0, green: 0, blue: 0))
        #expect(XtermPalette.color(21) == RGB(red: 0, green: 0, blue: 255))
        #expect(XtermPalette.color(196) == RGB(red: 255, green: 0, blue: 0))
        #expect(XtermPalette.color(110) == RGB(red: 135, green: 175, blue: 215))
        #expect(XtermPalette.color(232) == RGB(red: 8, green: 8, blue: 8))
        #expect(XtermPalette.color(255) == RGB(red: 238, green: 238, blue: 238))
        #expect(XtermPalette.color(15) == nil)
    }
}
