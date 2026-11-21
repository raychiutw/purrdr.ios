#if canImport(UIKit)
import UIKit
#endif

/// 收起軟體鍵盤:把 resignFirstResponder 送給目前的 first responder(輸入元件的委派會同步 SwiftUI 的焦點狀態)。
enum KeyboardDismissal {
    @MainActor
    static func dismiss() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}
