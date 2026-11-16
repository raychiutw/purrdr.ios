import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 承載文字的自訂顏色對比(#35;HIG 20.2:文字對比 ≥ 4.5:1,Increase Contrast 時 ≥ 7:1)。
@Suite("無障礙配色")
struct AccessibleColorsTests {
    /// 錯誤文字可能落在的背景裡最不利的那個(固定值，取自 iOS 系統色):
    /// 淺色是 shell 區塊的 `.fill.tertiary`(rgba(118,118,128,0.12))疊在白底上 = #EFEFF0;
    /// 深色是 grouped list 第二層 `secondarySystemGroupedBackground`／`secondarySystemBackground` = #2C2C2E。
    static let lightBackground = ThemeColor(red: 0xEF, green: 0xEF, blue: 0xF0)
    static let darkBackground = ThemeColor(red: 0x2C, green: 0x2C, blue: 0x2E)

    @Test("錯誤文字：深淺色 ≥ 4.5:1,高對比 ≥ 7:1")
    func errorTextContrast() {
        let palette = AccessibleColors.errorText
        let light = palette.light.contrastRatio(with: Self.lightBackground)
        let dark = palette.dark.contrastRatio(with: Self.darkBackground)
        let lightHigh = palette.lightHighContrast.contrastRatio(with: Self.lightBackground)
        let darkHigh = palette.darkHighContrast.contrastRatio(with: Self.darkBackground)
        #expect(light >= 4.5, "淺色 \(light)")
        #expect(dark >= 4.5, "深色 \(dark)")
        #expect(lightHigh >= 7, "淺色高對比 \(lightHigh)")
        #expect(darkHigh >= 7, "深色高對比 \(darkHigh)")
    }

    /// 次要文字可能落在的背景(固定值，取自 iOS 系統色):
    /// 淺色：主要背景 `systemBackground`／grouped 的列 #FFFFFF、grouped 背景 `systemGroupedBackground` #F2F2F7、
    /// 卡片與 shell 區塊的淡填色疊在白底上 #EFEFF0;
    /// 深色：主要背景 #000000、grouped 背景與 `secondarySystemBackground` #1C1C1E、grouped 的列 #2C2C2E。
    static let lightSecondaryBackgrounds = [
        ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF), ThemeColor(red: 0xF2, green: 0xF2, blue: 0xF7),
        ThemeColor(red: 0xEF, green: 0xEF, blue: 0xF0),
    ]
    static let darkSecondaryBackgrounds = [
        ThemeColor(red: 0x00, green: 0x00, blue: 0x00), ThemeColor(red: 0x1C, green: 0x1C, blue: 0x1E),
        ThemeColor(red: 0x2C, green: 0x2C, blue: 0x2E),
    ]

    @Test("次要文字：深淺色對主要與 grouped 背景 ≥ 4.5:1,高對比 ≥ 7:1")
    func secondaryTextContrast() {
        let palette = AccessibleColors.secondaryText
        let cases: [(String, ThemeColor, [ThemeColor], Double)] = [
            ("淺色", palette.light, Self.lightSecondaryBackgrounds, 4.5),
            ("深色", palette.dark, Self.darkSecondaryBackgrounds, 4.5),
            ("淺色高對比", palette.lightHighContrast, Self.lightSecondaryBackgrounds, 7),
            ("深色高對比", palette.darkHighContrast, Self.darkSecondaryBackgrounds, 7),
        ]
        for (name, color, backgrounds, minimum) in cases {
            for background in backgrounds {
                let ratio = color.contrastRatio(with: background)
                #expect(ratio >= minimum, "\(name) \(color) 對 \(background) 只有 \(ratio)")
            }
        }
    }
}
