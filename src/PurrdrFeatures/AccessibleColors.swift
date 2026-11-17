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
}

extension ShapeStyle where Self == Color {
    /// 錯誤文字的顏色(取代承載文字的系統 `.red`)。圖示與不承載文字的標記仍可用系統紅。
    static var errorText: Color { AccessibleColors.errorText.color }

    /// 承載資訊的次要文字顏色(取代系統 `.secondary`／`.tertiary` 文字)。圖示、分隔線、底色等純裝飾仍用系統階層色。
    static var secondaryText: Color { AccessibleColors.secondaryText.color }
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

extension AccessibleColors {
    /// 狀態條的閒置段(#103):比系統綠低飽和，非文字圖形對列背景 ≥ 3:1。
    static let idleSegment = ContrastPalette(
        light: ThemeColor(red: 0x4E, green: 0x9A, blue: 0x62),             // 白底 3.4:1
        dark: ThemeColor(red: 0x4A, green: 0xA5, blue: 0x5F),              // #1C1C1E 5.5:1、#2C2C2E 4.5:1
        lightHighContrast: ThemeColor(red: 0x2F, green: 0x7D, blue: 0x43), // 白底 5.1:1
        darkHighContrast: ThemeColor(red: 0x6B, green: 0xBF, blue: 0x7E)   // #1C1C1E 7.6:1、#2C2C2E 6.2:1
    )
}

/// Agent 種類頭像(#103):底色與白色字母。深淺色共用同一個底色，高對比時更深。
struct AgentKindAvatarStyle {
    var letter: String
    var palette: ContrastPalette

    init(kind: AgentKind) {
        let (letter, normal, highContrast): (String?, ThemeColor, ThemeColor) = switch kind {
        case .claudeCode: ("C", ThemeColor(red: 0xA8, green: 0x4A, blue: 0x2A), ThemeColor(red: 0x8F, green: 0x3E, blue: 0x22)) // 5.7／7.3:1
        case .codex: ("X", ThemeColor(red: 0x48, green: 0x48, blue: 0x4A), ThemeColor(red: 0x3A, green: 0x3A, blue: 0x3C)) // 9.1／11.4:1
        case .gemini: ("G", ThemeColor(red: 0x2F, green: 0x5F, blue: 0xCC), ThemeColor(red: 0x24, green: 0x4C, blue: 0xA8)) // 5.8／7.9:1
        case .openCode: ("O", ThemeColor(red: 0x23, green: 0x73, blue: 0x47), ThemeColor(red: 0x1B, green: 0x5E, blue: 0x39)) // 5.8／7.8:1
        case .copilot: ("P", ThemeColor(red: 0x73, green: 0x40, blue: 0xCF), ThemeColor(red: 0x5E, green: 0x2F, blue: 0xB0)) // 6.2／8.4:1
        // 其他種類：中性色 + 顯示名首字母。
        case .unknown: (nil, ThemeColor(red: 0x5A, green: 0x5A, blue: 0x5F), ThemeColor(red: 0x48, green: 0x48, blue: 0x4A)) // 6.9／9.1:1
        }
        self.letter = letter ?? (kind.displayName?.first.map { String($0).uppercased() } ?? "?")
        palette = ContrastPalette(light: normal, dark: normal, lightHighContrast: highContrast, darkHighContrast: highContrast)
    }
}
