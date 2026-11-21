import SwiftUI

/// 浮在內容上的玻璃控制(#348,DESIGN.md「Liquid Glass」):regular 變體;「減少透明度」時改不透明的系統底加細邊框,
/// 內容從底下捲過去時仍可讀。聊天的標題膠囊、輸入框、工作中膠囊與浮動橫幅共用。
struct FloatingGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.forcesOpaqueGlass) private var forcesOpaque

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || forcesOpaque {
            content
                .background(.background, in: shape)
                .overlay { shape.strokeBorder(.separator, lineWidth: 1) }
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

extension EnvironmentValues {
    /// UI 測試用:強制玻璃走不透明(模擬器無法用啟動參數開系統的「減少透明度」)。由 app 的 composition root 依啟動參數
    /// `-uiTestingReduceTransparency YES` 注入,畫面不自己讀 `UserDefaults`。
    @Entry public var forcesOpaqueGlass = false
}

extension View {
    /// 讓這個控制成為浮在內容上的玻璃(減少透明度時不透明)。
    func floatingGlass<S: InsettableShape>(in shape: S) -> some View {
        modifier(FloatingGlass(shape: shape))
    }
}
