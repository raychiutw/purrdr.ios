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
    static let inner = card
    #endif
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
    /// 部分高度 sheet 內的清單(#425):頁面底不鋪不透明色,讓系統 sheet 自己的玻璃透出(減少透明度時系統自動不透明,
    /// 拉到 large 時系統也改成實底);列仍用 `AppSurface.groupedRow`。全頁的清單用 `appGroupedList()`。
    func appSheetList() -> some View {
        scrollContentBackground(.hidden)
            .listRowBackground(AppSurface.groupedRow)
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
