import SwiftUI
#if canImport(UIKit)
import UIKit

/// 搜尋欄(`.searchable`)由系統的 `UISearchTextField` 畫:SwiftUI 的 tint 只能設在整個內容上(會連帶改到其他控制項),
/// 所以只對搜尋輸入框以外觀代理設成系統文字色(#647)。app 啟動時呼叫一次。
///
/// 副作用與限制(0.54 review 查證):
/// - 外觀代理是整個 process 的 `UISearchTextField`,包括之後新增的搜尋欄與系統元件在 app 內用到的;目前只有 `TopBarViews`、
///   `FolderBrowserView` 兩處 `.searchable`,符合需求,新增搜尋欄預期也要是 label 色,所以不縮小範圍。
/// - 外觀代理只在視圖加進視窗時套用「沒被明確設定過」的屬性;`.searchable` 由 UISearchController 的搜尋列承載,
///   原始碼與文件都看不出 SwiftUI 會對搜尋輸入框明確設 `tintColor`(app 主色是從上層「繼承」,不算明確設定),所以預期外觀代理生效。
///   **需實機確認**:游標、選取反白與輸入法膠囊在搜尋欄真的是 label 色(單元測試只能比對原始碼,看不到 UIKit 實際行為)。
@MainActor public enum InputFieldAppearance {
    public static func install() {
        UISearchTextField.appearance().tintColor = UIColor.label
    }
}
#endif

extension View {
    /// 文字輸入元件的 tint 是系統文字色(#647、spec #645):鍵盤輸入法提示膠囊(聽寫、「國」)、游標與選取反白都跟著,
    /// 深色白底深字、淺色黑底淺字。不用主色。
    func inputFieldTint() -> some View {
        tint(.primary)
    }
}
