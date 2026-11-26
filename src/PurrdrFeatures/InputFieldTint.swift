import SwiftUI
#if canImport(UIKit)
import UIKit

/// 搜尋欄(`.searchable`)由系統的 `UISearchTextField` 畫:SwiftUI 的 tint 只能設在整個內容上(會連帶改到其他控制項),
/// 所以只對搜尋輸入框以外觀代理設成系統文字色(#647)。app 啟動時呼叫一次。
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
