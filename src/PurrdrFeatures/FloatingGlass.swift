import SwiftUI

/// 浮在內容上的玻璃控制(#348,DESIGN.md「Liquid Glass」):regular 變體;「減少透明度」時改不透明的系統底加細邊框,
/// 內容從底下捲過去時仍可讀。聊天的標題膠囊、輸入框、工作中膠囊與浮動橫幅共用。
struct FloatingGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// UI 測試用:啟動參數 `-uiTestingReduceTransparency YES` 強制走不透明(模擬器無法用啟動參數開系統設定)。
    private static var forcesOpaque: Bool { UserDefaults.standard.bool(forKey: "uiTestingReduceTransparency") }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || Self.forcesOpaque {
            content
                .background(.background, in: shape)
                .overlay { shape.strokeBorder(.separator, lineWidth: 1) }
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    /// 讓這個控制成為浮在內容上的玻璃(減少透明度時不透明)。
    func floatingGlass<S: InsettableShape>(in shape: S) -> some View {
        modifier(FloatingGlass(shape: shape))
    }
}
