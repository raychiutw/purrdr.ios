import PurrdrAgentFeatures
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

    /// iPad 列表選取列的底色(#95):紅底角色。系統的選取底色是 tint(紅字角色),深色白字只有 3.0:1。
    static let selectionFill = brandFill

    /// 選取列上的文字與「需要你」(符號與狀態字)。
    static let selectedRowText = ContrastPalette(
        light: ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF),             // 選取底色 4.6:1
        dark: ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF),              // 選取底色 4.6:1
        lightHighContrast: ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF), // 選取底色 7.1:1
        darkHighContrast: ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF)   // 選取底色 7.1:1
    )

    /// 停止列「已停止」的文字(#220)。
    static let successText = ContrastPalette(
        light: ThemeColor(red: 0x24, green: 0x8A, blue: 0x3D),
        dark: ThemeColor(red: 0x30, green: 0xD1, blue: 0x58),
        lightHighContrast: ThemeColor(red: 0x24, green: 0x8A, blue: 0x3D),
        darkHighContrast: ThemeColor(red: 0x30, green: 0xD1, blue: 0x58)
    )

    /// 停止列「仍在工作」「無法確認」的文字(#220)。
    static let warningText = ContrastPalette(
        light: ThemeColor(red: 0xC2, green: 0x5E, blue: 0x00),
        dark: ThemeColor(red: 0xFF, green: 0x9F, blue: 0x0A),
        lightHighContrast: ThemeColor(red: 0xC2, green: 0x5E, blue: 0x00),
        darkHighContrast: ThemeColor(red: 0xFF, green: 0x9F, blue: 0x0A)
    )

    /// 對話中的連結(#93):系統連結藍的色相(`#007AFF`／`#0A84FF`),只調明度。
    /// 系統 `.link` 淺色對 `#EFEFF0` 只有 3.5:1、深色對 `#2C2C2E` 3.8:1,不能承載文字。
    static let linkText = ContrastPalette(
        light: ThemeColor(red: 0x00, green: 0x68, blue: 0xDA),             // 白底 5.3:1、#F2F2F7 4.7:1、#EFEFF0 4.6:1
        dark: ThemeColor(red: 0x2D, green: 0x96, blue: 0xFF),              // 黑底 6.9:1、#1C1C1E 5.6:1、#2C2C2E 4.6:1
        lightHighContrast: ThemeColor(red: 0x00, green: 0x4D, blue: 0xA2), // #EFEFF0 7.1:1
        darkHighContrast: ThemeColor(red: 0x7D, green: 0xBE, blue: 0xFF)   // #2C2C2E 7.1:1
    )
}

extension ShapeStyle where Self == Color {
    /// 錯誤文字的顏色(取代承載文字的系統 `.red`)。圖示與不承載文字的標記仍可用系統紅。
    static var errorText: Color { AccessibleColors.errorText.color }

    /// 承載資訊的次要文字顏色(取代系統 `.secondary`／`.tertiary` 文字)。圖示、分隔線、底色等純裝飾仍用系統階層色。
    static var secondaryText: Color { AccessibleColors.secondaryText.color }

    /// 承載白字的品牌紅填色(紅底角色)。紅字與 tint 用 `AccentColor`。
    static var brandFill: Color { AccessibleColors.brandFill.color }

    /// iPad 選取列上的文字與「需要你」。
    static var selectedRowText: Color { AccessibleColors.selectedRowText.color }

    /// 對話中連結的顏色(連結藍，不用品牌紅 tint)。
    static var linkText: Color { AccessibleColors.linkText.color }
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

extension AccessibleColors {
    /// 方案用量圓環的顏色(#177):依剩餘比例分三級。
    /// 非文字圖形，對列背景(白、#1C1C1E、#2C2C2E)≥ 3:1,高對比 ≥ 4.5:1。
    static func planUsage(_ level: PlanUsageLevel) -> ContrastPalette {
        switch level {
        case .ample: planUsageAmple
        case .low: planUsageLow
        case .depleted: planUsageDepleted
        }
    }

    static let planUsageAmple = ContrastPalette(
        light: ThemeColor(red: 0x24, green: 0x8A, blue: 0x3D),             // 白底 4.4:1
        dark: ThemeColor(red: 0x30, green: 0xD1, blue: 0x58),              // #1C1C1E 8.4:1、#2C2C2E 6.9:1
        lightHighContrast: ThemeColor(red: 0x1E, green: 0x7A, blue: 0x35), // 白底 5.4:1
        darkHighContrast: ThemeColor(red: 0x5F, green: 0xE0, blue: 0x7E)   // #2C2C2E 8.3:1
    )

    static let planUsageLow = ContrastPalette(
        light: ThemeColor(red: 0xC2, green: 0x5E, blue: 0x00),             // 白底 4.3:1
        dark: ThemeColor(red: 0xFF, green: 0x9F, blue: 0x0A),              // #1C1C1E 8.3:1、#2C2C2E 6.8:1
        lightHighContrast: ThemeColor(red: 0x9A, green: 0x4A, blue: 0x00), // 白底 6.3:1
        darkHighContrast: ThemeColor(red: 0xFF, green: 0xB3, blue: 0x40)   // #2C2C2E 7.8:1
    )

    static let planUsageDepleted = ContrastPalette(
        light: ThemeColor(red: 0xD7, green: 0x00, blue: 0x15),             // 白底 5.4:1
        dark: ThemeColor(red: 0xFF, green: 0x69, blue: 0x61),              // #1C1C1E 6.0:1、#2C2C2E 4.9:1
        lightHighContrast: ThemeColor(red: 0xA5, green: 0x00, blue: 0x11), // 白底 8.1:1
        darkHighContrast: ThemeColor(red: 0xFF, green: 0x9F, blue: 0x97)   // #2C2C2E 7.1:1
    )
}
