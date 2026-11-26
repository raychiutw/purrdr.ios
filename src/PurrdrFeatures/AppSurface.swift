import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// App 的底色層次(#379)。深色頁面不用系統的純黑:頁面 `#1C1C1E`、卡片與 grouped 列 `#2C2C2E`、再內一層 `#3A3A3C`。
///
/// 淺色沿用系統語意色。SwiftUI 的 `.background`、`List`／`Form` 預設底色不吃視窗的 `userInterfaceLevel`
/// (實測視窗與視圖的 level 都是 elevated,畫出來仍是純黑),所以深色值要明確寫在這裡,
/// 畫面一律用這些語意名稱,不在各處寫死色碼。
/// sheet 的系統底色本來就是 elevated(`#1C1C1E`、列 `#2C2C2E`),與這組深色值相同,所以 sheet 裡不論用系統色或這組都一致
/// (使用者決定接受:不做設計稿的 sheet 再高一階)。
enum AppSurface {
    /// 深色值(RGB 整數),測試與對比檢查共用。
    static let darkPage = 0x1C1C1E
    static let darkCard = 0x2C2C2E
    static let darkInner = 0x3A3A3C

    #if canImport(UIKit)
    /// 頁面底色(取代 `.background`)。
    static let page = dynamic(dark: darkPage, light: .systemBackground)
    /// grouped 清單的頁面底色(取代 `systemGroupedBackground`)。
    static let groupedPage = dynamic(dark: darkPage, light: .systemGroupedBackground)
    /// 頁面上的卡片(取代 `.background.secondary`)。
    static let card = dynamic(dark: darkCard, light: .secondarySystemBackground)
    /// grouped 清單的列(取代 `secondarySystemGroupedBackground`)。
    static let groupedRow = dynamic(dark: darkCard, light: .secondarySystemGroupedBackground)
    /// 卡片或列裡再內一層。
    static let inner = dynamic(dark: darkInner, light: .tertiarySystemBackground)

    private static func dynamic(dark: Int, light: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: CGFloat((dark >> 16) & 0xFF) / 255, green: CGFloat((dark >> 8) & 0xFF) / 255,
                          blue: CGFloat(dark & 0xFF) / 255, alpha: 1)
                : light.resolvedColor(with: traits)
        })
    }
    #else
    // macOS(只跑 swift test):沒有 UIKit 的系統語意色,用 SwiftUI 預設。
    static let page = Color(nsColor: .windowBackgroundColor)
    static let groupedPage = page
    static let card = Color(nsColor: .controlBackgroundColor)
    static let groupedRow = card
    static let sheet = page
    static let inner = card
    #endif

    /// iPad 寬視窗下頁面內容的寬度上限(主機 tab 原本的 720pt)。
    static let pageContentWidth: CGFloat = 720
}

extension View {
    /// grouped 清單／表單套用 App 底色層次:頁面與列都用 `AppSurface`。
    func appGroupedList() -> some View {
        scrollContentBackground(.hidden)
            .background(AppSurface.groupedPage)
            .listRowBackground(AppSurface.groupedRow)
    }
}

extension View {
    /// 全頁清單在 iPad 寬視窗不拉滿整個螢幕(HIG:內容寬度跟閱讀寬度):上限 `AppSurface.pageContentWidth`、置中,
    /// 兩側露出頁面底色。iPhone 與窄視窗寬度不到上限,等於沒有作用。
    func appPageContentWidth() -> some View {
        frame(maxWidth: AppSurface.pageContentWidth)
            .frame(maxWidth: .infinity)
            .background(AppSurface.groupedPage)
    }
}

extension View {
    /// sheet 內的清單(#614):隱藏清單預設的頁面底,讓 sheet 的系統 Liquid Glass 透出來(半高透出、全高由系統變不透明);
    /// 列底用系統預設,不自訂不透明底色。可讀性交給系統,「減少透明度」也由系統處理。
    func appSheetList() -> some View {
        scrollContentBackground(.hidden)
    }

    /// 有 detent 的 sheet:只設 `presentationDetents`,不蓋 sheet 的系統玻璃(`GlassLevelUsageTests` 守門)。
    func appSheet(detents: Set<PresentationDetent>) -> some View {
        presentationDetents(detents)
    }

    /// NavigationStack 內容的底色用 `AppSurface.page`(沒有自己底色的空狀態、對話)。
    @ViewBuilder
    func appNavigationBackground() -> some View {
        #if os(iOS)
        containerBackground(AppSurface.page, for: .navigation)
        #else
        self
        #endif
    }
}
