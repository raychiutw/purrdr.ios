import SwiftUI

/// 浮在內容上的玻璃控制(#348,DESIGN.md「Liquid Glass」):系統 regular 變體,
/// 「減少透明度」等輔助功能設定由系統的玻璃自己處理,不另寫不透明版本(#614)。聊天的輸入框、工作中膠囊與浮動橫幅共用。
struct FloatingGlass<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: shape).dimsWhenWindowInactive()
    }
}

extension EnvironmentValues {
    /// UI 測試用:處理 `purrdr://testing-…` 測試連結(不重啟換字級)。由 composition root 依 `-uiTesting` 注入。
    @Entry public var allowsTestingLinks = false
    /// UI 測試用:聊天列表量測閱讀位移(驗收用)。由 composition root 依 `LaunchConfiguration.tracksReadingDrift` 注入。
    @Entry public var tracksReadingDrift = false
    /// UI 測試用:無障礙稽核時隱藏除錯層。由 composition root 依 `LaunchConfiguration.hidesDebugOverlay` 注入。
    @Entry public var hidesDebugOverlay = false
}

extension View {
    /// 讓這個控制成為浮在內容上的玻璃(輔助功能設定由系統處理)。
    func floatingGlass<S: InsettableShape>(in shape: S) -> some View {
        modifier(FloatingGlass(shape: shape))
    }
}
