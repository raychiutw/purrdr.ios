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

    /// 承載資訊的次要文字(副標、時間、說明、預覽、參數提示等;#67)。
    /// 系統 `.secondary`(secondaryLabel)在白底只有 3.4:1、在 grouped 背景 #F2F2F7 3.1:1;
    /// `.tertiary` 更淡(約 2:1)。純裝飾(圖示、分隔線、底色)仍可用系統階層色。
    static let secondaryText = ContrastPalette(
        light: ThemeColor(red: 0x63, green: 0x63, blue: 0x66),             // 白底 6.0:1、#F2F2F7 5.4:1、#EFEFF0 5.2:1
        dark: ThemeColor(red: 0xAE, green: 0xAE, blue: 0xB2),              // 黑底 9.5:1、#1C1C1E 7.7:1、#2C2C2E 6.3:1
        lightHighContrast: ThemeColor(red: 0x48, green: 0x48, blue: 0x4A), // 白底 9.1:1、#F2F2F7 8.2:1、#EFEFF0 7.9:1
        darkHighContrast: ThemeColor(red: 0xD1, green: 0xD1, blue: 0xD6)   // 黑底 13.8:1、#1C1C1E 11.2:1、#2C2C2E 9.2:1
    )

    /// 紅字(品牌紅的文字與 tint 角色;#70)。Asset Catalog 的 `AccentColor` 與它同值。
    /// 色相與飽和度同 `#FA2D48`,只調明度。
    static let brandText = ContrastPalette(
        light: ThemeColor(red: 0xD8, green: 0x05, blue: 0x21),             // #EFEFF0 4.6:1、#F2F2F7 4.7:1、白底 5.3:1
        dark: ThemeColor(red: 0xFC, green: 0x5D, blue: 0x72),              // #2C2C2E 4.6:1、#1C1C1E 5.6:1、黑底 6.9:1
        lightHighContrast: ThemeColor(red: 0xA2, green: 0x04, blue: 0x19), // #EFEFF0 7.1:1
        darkHighContrast: ThemeColor(red: 0xFC, green: 0xA1, blue: 0xAD)   // #2C2C2E 7.1:1
    )

    /// 紅底(承載白字的品牌紅填色;#70):送出鍵、使用者泡泡、主要按鈕、膠囊標籤。深色模式不跟著紅字變亮。
    static let brandFill = ContrastPalette(
        light: ThemeColor(red: 0xEA, green: 0x08, blue: 0x26),             // 白字 4.6:1
        dark: ThemeColor(red: 0xEA, green: 0x08, blue: 0x26),
        lightHighContrast: ThemeColor(red: 0xB3, green: 0x04, blue: 0x1B), // 白字 7.1:1
        darkHighContrast: ThemeColor(red: 0xB3, green: 0x04, blue: 0x1B)
    )
}

extension ShapeStyle where Self == Color {
    /// 錯誤文字的顏色(取代承載文字的系統 `.red`)。圖示與不承載文字的標記仍可用系統紅。
    static var errorText: Color { AccessibleColors.errorText.color }

    /// 承載資訊的次要文字顏色(取代系統 `.secondary`／`.tertiary` 文字)。圖示、分隔線、底色等純裝飾仍用系統階層色。
    static var secondaryText: Color { AccessibleColors.secondaryText.color }

    /// 承載白字的品牌紅填色(紅底角色)。紅字與 tint 用 `AccentColor`。
    static var brandFill: Color { AccessibleColors.brandFill.color }
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
