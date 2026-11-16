import PurrdrCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 一個自訂顏色的四個值(DESIGN.md:light／dark／各自 high contrast)。
struct ContrastPalette: Sendable {
    var light: ThemeColor
    var dark: ThemeColor
    var lightHighContrast: ThemeColor
    var darkHighContrast: ThemeColor

    /// 依外觀與「增加對比」取值的顏色。
    var color: Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            return switch (traits.userInterfaceStyle == .dark, high) {
            case (false, false): UIColor(light)
            case (true, false): UIColor(dark)
            case (false, true): UIColor(lightHighContrast)
            case (true, true): UIColor(darkHighContrast)
            }
        })
        #else
        Color(light)
        #endif
    }
}

/// 承載文字的系統色對比不足時的替代色(#35)。
enum AccessibleColors {
    /// 錯誤文字(`!` 指令的 stderr、失敗的工具結果、表單與狀態的錯誤訊息)。
    /// 系統 `.red`(#FF3B30)在白底只有 3.6:1、在 shell 區塊的填色底 3.1:1,不能承載文字。
    static let errorText = ContrastPalette(
        light: ThemeColor(red: 0xC4, green: 0x00, blue: 0x1A),             // 對 #EFEFF0 5.4:1、白底 6.3:1
        dark: ThemeColor(red: 0xFF, green: 0x7A, blue: 0x70),              // 對 #2C2C2E 5.5:1、黑底 8.3:1
        lightHighContrast: ThemeColor(red: 0xA5, green: 0x00, blue: 0x11), // 對 #EFEFF0 7.0:1
        darkHighContrast: ThemeColor(red: 0xFF, green: 0x9F, blue: 0x97)   // 對 #2C2C2E 7.1:1
    )
}

extension ShapeStyle where Self == Color {
    /// 錯誤文字的顏色(取代承載文字的系統 `.red`)。圖示與不承載文字的標記仍可用系統紅。
    static var errorText: Color { AccessibleColors.errorText.color }
}

/// 文字按鈕的 label,觸控目標至少 44×44 pt(HIG 20.2)。
///
/// `frame(minHeight: 44)` 要放在 label 裡面:放在 `Button` 外面只撐大排版，可點範圍與 accessibility frame
/// 仍然只有文字大小(#35 的 accessibility audit 抓到的 hit region 問題)。
struct HitTarget: View {
    let title: Text

    init(_ title: LocalizedStringKey) {
        self.title = Text(title)
    }

    var body: some View {
        title
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
    }
}
