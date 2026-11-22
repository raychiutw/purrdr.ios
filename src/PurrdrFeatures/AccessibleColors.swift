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
    /// 承載資訊的次要文字(副標、時間、說明、預覽、參數提示等;#67)。
    /// 系統 `.secondary`(secondaryLabel)在白底只有 3.4:1、在 grouped 背景 #F2F2F7 3.1:1;
    /// `.tertiary` 更淡(約 2:1)。純裝飾(圖示、分隔線、底色)仍可用系統階層色。
    static let secondaryText = ContrastPalette(
        light: ThemeColor(red: 0x63, green: 0x63, blue: 0x66),             // 白底 6.0:1、#F2F2F7 5.4:1、#EFEFF0 5.2:1
        dark: ThemeColor(red: 0xAE, green: 0xAE, blue: 0xB2),              // 黑底 9.5:1、#1C1C1E 7.7:1、#2C2C2E 6.3:1
        lightHighContrast: ThemeColor(red: 0x48, green: 0x48, blue: 0x4A), // 白底 9.1:1、#F2F2F7 8.2:1、#EFEFF0 7.9:1
        darkHighContrast: ThemeColor(red: 0xD1, green: 0xD1, blue: 0xD6)   // 黑底 13.8:1、#1C1C1E 11.2:1、#2C2C2E 9.2:1
    )

    /// 主色上的字與符號(ADR-0011):主色本身只有 Asset Catalog 的 `AccentColor` 一份，這組只配它當底。
    /// 淺色白字(`#0B7A5C` 5.3:1、高對比 `#075C45` 8.0:1),深色黑字(`#3CCF9E` 10.6:1、高對比 `#5DE0B3` 12.8:1)。
    static let onAccent = ContrastPalette(
        light: ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF),
        dark: ThemeColor(red: 0x00, green: 0x00, blue: 0x00),
        lightHighContrast: ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF),
        darkHighContrast: ThemeColor(red: 0x00, green: 0x00, blue: 0x00)
    )
}

extension AccessibleColors {
    /// 紅字按鈕(刪除、重設、強制結束;#379):系統紅 #FF453A 在深色的 #2C2C2E 以上只有約 4.1:1,
    /// 所以文字改用這組(圖示、填色與分隔等非文字仍用系統紅)。
    static let destructiveText = ContrastPalette(
        light: ThemeColor(red: 0xD7, green: 0x00, blue: 0x15),             // 白底 5.4:1
        dark: ThemeColor(red: 0xFF, green: 0x8A, blue: 0x82),              // 設計稿 redtext;對 #3A3A3C 以上 ≥ 4.5:1
        lightHighContrast: ThemeColor(red: 0xA5, green: 0x00, blue: 0x11), // 白底 8.1:1
        darkHighContrast: ThemeColor(red: 0xFF, green: 0xC7, blue: 0xC2)
    )
}

extension ShapeStyle where Self == Color {
    /// 紅字按鈕的文字顏色(`AccessibleColors.destructiveText`)。
    static var destructiveText: Color { AccessibleColors.destructiveText.color }

    /// 承載資訊的次要文字顏色(取代系統 `.secondary`／`.tertiary` 文字)。圖示、分隔線、底色等純裝飾仍用系統階層色。
    static var secondaryText: Color { AccessibleColors.secondaryText.color }

    /// 主色(`AccentColor`)底上的字與符號。
    static var onAccent: Color { AccessibleColors.onAccent.color }

    /// iPad 分欄選取列的中性灰底(系統 `systemGray5`,#238);文字維持主要色與次要文字色。
    static var neutralSelection: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGray5)
        #else
        Color.gray.opacity(0.2)
        #endif
    }
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

/// Agent 種類頭像(#103;#242 低飽和多色):底色與白色字母。深淺色共用同一個底色，高對比時更深。
struct AgentKindAvatarStyle {
    var letter: String
    var palette: ContrastPalette

    init(kind: AgentKind) {
        let (letter, normal, highContrast): (String?, ThemeColor, ThemeColor) = switch kind {
        case .claudeCode: ("C", ThemeColor(red: 0x8A, green: 0x5A, blue: 0x48), ThemeColor(red: 0x6D, green: 0x47, blue: 0x39)) // 5.8／8.0:1
        case .codex: ("X", ThemeColor(red: 0x55, green: 0x56, blue: 0x5C), ThemeColor(red: 0x4F, green: 0x50, blue: 0x56)) // 7.3／8.0:1
        case .gemini: ("G", ThemeColor(red: 0x4A, green: 0x5F, blue: 0x86), ThemeColor(red: 0x3E, green: 0x50, blue: 0x71)) // 6.4／8.1:1
        case .openCode: ("O", ThemeColor(red: 0x5C, green: 0x6B, blue: 0x4A), ThemeColor(red: 0x48, green: 0x53, blue: 0x3A)) // 5.7／8.2:1
        case .copilot: ("P", ThemeColor(red: 0x6A, green: 0x58, blue: 0x84), ThemeColor(red: 0x58, green: 0x49, blue: 0x6E)) // 6.3／8.1:1
        // 其他種類：中性色 + 顯示名首字母。
        case .unknown: (nil, ThemeColor(red: 0x5A, green: 0x5A, blue: 0x5F), ThemeColor(red: 0x50, green: 0x50, blue: 0x55)) // 6.9／8.0:1
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

extension AccessibleColors {
    /// 數據用量長條圖的兩階綠(#354,原型 `prototypes/data-usage/`,已以色盲檢查腳本驗證):
    /// 行動網路(淺色深綠、深色亮綠)與 Wi-Fi(淺色淺綠、深色暗綠)。亮度差別讓兩段不只靠色相分辨;圖例與數值另有文字。
    static let dataUsageCellular = ContrastPalette(
        light: ThemeColor(red: 0x0B, green: 0x7A, blue: 0x5C),
        dark: ThemeColor(red: 0x2B, green: 0xB3, blue: 0x83),
        lightHighContrast: ThemeColor(red: 0x07, green: 0x5C, blue: 0x45),
        darkHighContrast: ThemeColor(red: 0x5D, green: 0xE0, blue: 0xB3)
    )

    static let dataUsageWifi = ContrastPalette(
        light: ThemeColor(red: 0x5B, green: 0xB8, blue: 0x94),
        dark: ThemeColor(red: 0x12, green: 0x7A, blue: 0x59),
        lightHighContrast: ThemeColor(red: 0x4A, green: 0xA8, blue: 0x84),
        darkHighContrast: ThemeColor(red: 0x1A, green: 0x8F, blue: 0x6A)
    )
}
