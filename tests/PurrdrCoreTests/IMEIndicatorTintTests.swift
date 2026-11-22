import PurrdrCore
import Testing

/// 輸入法指示膠囊(聽寫、「國」)由系統以輸入元件的 tint 為底、白字繪製(#396):
/// 深色模式的 tint 是亮翡翠綠,白字對比不到 2:1;換成讓白字對比 ≥ 4.5:1 的深一點的同色相。
@Suite("輸入法指示膠囊的 tint")
struct IMEIndicatorTintTests {
    static let darkAccent = ThemeColor(hex: "#3CCF9E")!
    static let lightAccent = ThemeColor(hex: "#0B7A5C")!
    static let white = ThemeColor(hex: "#ffffff")!

    @Test("深色模式的主色(#3CCF9E)調整後與白字對比至少 4.5:1")
    func darkAccentGetsReadableWhiteText() {
        #expect(Self.darkAccent.contrastRatio(with: Self.white) < 4.5)
        let adjusted = Self.darkAccent.darkenedForWhiteText()
        #expect(adjusted.contrastRatio(with: Self.white) >= 4.5)
    }

    @Test("已經夠對比的顏色(淺色模式的主色)原樣不動")
    func sufficientColorUnchanged() {
        #expect(Self.lightAccent.darkenedForWhiteText() == Self.lightAccent)
    }

    @Test("調整保持色相:只往黑色混合,不超過需要的程度")
    func keepsHueAndDarkensMinimally() {
        let adjusted = Self.darkAccent.darkenedForWhiteText()
        #expect(adjusted.green >= adjusted.blue && adjusted.blue >= adjusted.red)
        #expect(adjusted.contrastRatio(with: Self.white) < 4.7)
    }
}
