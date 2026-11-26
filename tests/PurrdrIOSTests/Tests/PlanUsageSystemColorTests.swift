#if os(iOS)
import Testing
import UIKit
@testable import PurrdrFeatures

/// 70% 級距深色(含增加對比)是「實際的」系統橙(#649):`ContrastPalette.uiColor` 在深色特徵下解析出的值,
/// 要等於 `UIColor.systemOrange` 在同一組特徵下的解析值,而不是存起來的近似值(macOS 的 `AccessibleColorsTests` 只能比近似值)。
@Suite
@MainActor
struct PlanUsageSystemColorTests {
    private static func components(_ color: UIColor, _ traits: UITraitCollection) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    private static func traits(dark: Bool, high: Bool) -> UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: high ? .high : .normal),
        ])
    }

    @Test("深色與深色增加對比:70% 級距解析出的顏色就是 UIColor.systemOrange 在同特徵下的值")
    func darkIsTheRealSystemOrange() {
        let low = AccessibleColors.planUsageLow.uiColor
        for high in [false, true] {
            let traits = Self.traits(dark: true, high: high)
            #expect(Self.components(low, traits) == Self.components(.systemOrange, traits), "dark high=\(high)")
        }
    }

    @Test("淺色:70% 級距不是系統橙(系統橙對白底只有 2.2:1,所以用自訂色)")
    func lightIsCustom() {
        let low = AccessibleColors.planUsageLow.uiColor
        for high in [false, true] {
            let traits = Self.traits(dark: false, high: high)
            #expect(Self.components(low, traits) != Self.components(.systemOrange, traits), "light high=\(high)")
        }
    }
}
#endif
