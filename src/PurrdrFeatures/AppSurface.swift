import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// App 的底色(#646,取代 #379 的自訂深色層次):一律對應系統語意背景色。
///
/// 深色頁面是系統 base 純黑,sheet、popover 由系統自動 elevated 提亮一階;「增加對比」也跟著系統
/// (HIG〈Dark Mode〉Prefer the system background colors;值與研究見 `docs/research/ios27-dark-mode-colors.md`)。
/// 畫面用這些語意名稱,不寫死色碼(`SystemSurfaceUsageTests` 守門)。
enum AppSurface {
    #if canImport(UIKit)
    /// 頁面底色(`systemBackground`)。
    static let page = Color(uiColor: .systemBackground)
    /// grouped 清單的頁面底色(`systemGroupedBackground`)。
    static let groupedPage = Color(uiColor: .systemGroupedBackground)
    /// 頁面上的卡片(`secondarySystemBackground`)。
    static let card = Color(uiColor: .secondarySystemBackground)
    /// grouped 清單的列(`secondarySystemGroupedBackground`)。
    static let groupedRow = Color(uiColor: .secondarySystemGroupedBackground)
    /// 卡片或列裡再內一層(`tertiarySystemBackground`)。
    static let inner = Color(uiColor: .tertiarySystemBackground)
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
