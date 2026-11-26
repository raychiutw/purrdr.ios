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
    #if canImport(UIKit)
    /// 同 `color` 的 UIKit 版(給 UIKit appearance 用)。
    var uiColor: UIColor {
        UIColor { traits in
            let high = traits.accessibilityContrast == .high
            return switch (traits.userInterfaceStyle == .dark, high) {
            case (false, false): UIColor(light)
            case (true, false): UIColor(dark)
            case (false, true): UIColor(lightHighContrast)
            case (true, true): UIColor(darkHighContrast)
            }
        }
    }
    #endif

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

/// 只在淺色外觀使用的自訂色(深色交給系統色):一般與增加對比兩個值。
struct LightColorPair: Sendable {
    var normal: ThemeColor
    var highContrast: ThemeColor
}

/// 承載文字的系統色對比不足時的替代色(#35)。
enum AccessibleColors {
    /// 承載資訊的次要文字(副標、時間、說明、預覽、參數提示等;#67、#646)。
    /// 深色(含增加對比)用系統 `secondaryLabel`(對純黑 6.4:1、對 elevated 的 `#3A3A3C` 4.6:1,已達 4.5:1);
    /// 淺色系統 `secondaryLabel` 在白底只有 3.4:1、在 grouped 背景 #F2F2F7 3.1:1,所以淺色維持自訂灰。
    /// `.tertiary` 更淡(約 2:1);純裝飾(圖示、分隔線、底色)仍可用系統階層色。
    static let secondaryTextLight = LightColorPair(
        normal: ThemeColor(red: 0x63, green: 0x63, blue: 0x66),        // 白底 6.0:1、#F2F2F7 5.4:1、#EFEFF0 5.2:1
        highContrast: ThemeColor(red: 0x48, green: 0x48, blue: 0x4A)   // 白底 9.1:1、增加對比的 #EBEBF0 7.7:1
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
    /// 紅字按鈕(刪除、重設、強制結束;#379、#646):系統紅 #FF453A 在深色的 #2C2C2E 以上只有約 4.1:1,
    /// 所以文字改用這組(圖示、填色與分隔等非文字仍用系統紅)。對實際出現的系統背景
    /// (淺色 #FFFFFF／#F2F2F7／#EBEBF0、深色 base 與 elevated 含增加對比至 #444446)一般 ≥ 4.5:1、增加對比 ≥ 7:1(`AccessibleColorsTests`)。
    static let destructiveText = ContrastPalette(
        light: ThemeColor(red: 0xD7, green: 0x00, blue: 0x15),             // 白底 5.4:1
        dark: ThemeColor(red: 0xFF, green: 0x8A, blue: 0x82),              // 設計稿 redtext;對 #3A3A3C 以上 ≥ 4.5:1
        lightHighContrast: ThemeColor(red: 0x9C, green: 0x00, blue: 0x10), // 白底 8.7:1、#EBEBF0 7.3:1
        darkHighContrast: ThemeColor(red: 0xFF, green: 0xD3, blue: 0xCF)  // #444446 7.2:1
    )
}

extension AccessibleColors {
    /// 聊天 tab 未讀數字徽章的底色(白字;#639)。
    static let unreadBadge = ContrastPalette(
        light: ThemeColor(red: 0xD7, green: 0x00, blue: 0x15),             // 白字 5.4:1(系統紅 #FF3B30 只有 3.6:1)
        dark: ThemeColor(red: 0xD7, green: 0x00, blue: 0x15),              // 白字 5.4:1(系統紅 #FF453A 只有 3.3:1)
        lightHighContrast: ThemeColor(red: 0xA5, green: 0x00, blue: 0x11), // 白字 8.1:1
        darkHighContrast: ThemeColor(red: 0xA5, green: 0x00, blue: 0x11)
    )
}

extension ShapeStyle where Self == Color {
    /// 紅字按鈕的文字顏色(`AccessibleColors.destructiveText`)。
    static var destructiveText: Color { AccessibleColors.destructiveText.color }

    /// 承載資訊的次要文字顏色(取代系統 `.secondary`／`.tertiary` 文字)。圖示、分隔線、底色等純裝飾仍用系統階層色。
    static var secondaryText: Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark { return .secondaryLabel.resolvedColor(with: traits) }
            let pair = AccessibleColors.secondaryTextLight
            return UIColor(traits.accessibilityContrast == .high ? pair.highContrast : pair.normal)
        })
        #else
        Color(AccessibleColors.secondaryTextLight.normal)
        #endif
    }

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
        let presentation = AgentCatalog.profile(for: kind.agentID).presentation
        let avatar = presentation.avatar
        // 沒有專屬字母的種類：顯示名首字母。
        letter = avatar.letter ?? (presentation.displayName?.first.map { String($0).uppercased() } ?? "?")
        palette = ContrastPalette(light: avatar.normal, dark: avatar.normal, lightHighContrast: avatar.highContrast, darkHighContrast: avatar.highContrast)
    }
}

extension AccessibleColors {
    /// 低飽和用量色(#389、DESIGN.md「低飽和用量色」):用量條、圓環與 context 圓環依已用比例分三級(70% 起偏高、85% 起將用完)。
    /// 顏色只上圖形,數字另寫、到門檻加三角形,不只靠顏色。非文字圖形對軌道 ≥ 3:1(`PlanUsageColorsTests`),高對比 ≥ 4.5:1。
    static func planUsage(_ level: PlanUsageLevel) -> ContrastPalette {
        switch level {
        case .ample: planUsageAmple
        case .low: planUsageLow
        case .depleted: planUsageDepleted
        }
    }

    static let planUsageAmple = ContrastPalette(
        light: ThemeColor(red: 0x3D, green: 0x75, blue: 0x61),             // 對軌道 4.0:1(設計稿 #4F8572 只有 3.2:1)
        dark: ThemeColor(red: 0x6F, green: 0xAE, blue: 0x98),
        lightHighContrast: ThemeColor(red: 0x2F, green: 0x5E, blue: 0x4E),
        darkHighContrast: ThemeColor(red: 0x9F, green: 0xDC, blue: 0xC4)
    )

    static let planUsageLow = ContrastPalette(
        light: ThemeColor(red: 0xA9, green: 0x78, blue: 0x4A),
        dark: ThemeColor(red: 0xC9, green: 0x9A, blue: 0x6A),
        lightHighContrast: ThemeColor(red: 0x7D, green: 0x52, blue: 0x30),
        darkHighContrast: ThemeColor(red: 0xEB, green: 0xC4, blue: 0x98)
    )

    static let planUsageDepleted = ContrastPalette(
        light: ThemeColor(red: 0xB0, green: 0x64, blue: 0x5D),
        dark: ThemeColor(red: 0xC9, green: 0x80, blue: 0x78),
        lightHighContrast: ThemeColor(red: 0x84, green: 0x3D, blue: 0x38),
        darkHighContrast: ThemeColor(red: 0xEF, green: 0xAE, blue: 0xA7)
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
