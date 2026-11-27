import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 全 app 共用的「頂端不要遮罩」頁面設定(#682、spec #681,DESIGN.md「可讀性」)。
///
/// 使用者的決定(參考 Claude app):頁面往下捲時,頂端不要導覽列高度的 scroll edge effect(模糊加變暗),
/// 內容直接從浮動的返回鈕、標題膠囊後面捲過去;只在狀態列高度留一條由上往下淡出的模糊。
/// 開「減少透明度」時,狀態列那條改成不透明的系統底色。底部的效果不動(維持系統預設)。
///
/// 頂端 scroll edge effect 只在這個檔案決定(`TopEdgeEffectUsageTests` 守門):SwiftUI 頁面套 `appPageTopEdge()`,
/// UIKit 的捲動視圖呼叫 `hidesTopEdgeEffect()`。
extension View {
    /// 只關掉捲動容器的頂端 scroll edge effect(不疊狀態列淡模糊):sheet 與頁面內的捲動區用,
    /// sheet 的頂端不是狀態列,不該在那裡疊一條模糊。
    func appScrollTopEdge() -> some View {
        scrollEdgeEffectHidden(true, for: .top)
    }

    /// 關掉這頁捲動容器的頂端 scroll edge effect,並在狀態列高度疊一條淡出的模糊。
    func appPageTopEdge() -> some View {
        modifier(PageTopEdgeModifier())
    }
}

private struct PageTopEdgeModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .top)
            #if os(iOS)
            .overlay(alignment: .top) {
                StatusBarFade(reduceTransparency: reduceTransparency)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            #endif
    }
}

#if os(iOS)
extension UIScrollView {
    /// 關掉頂端 scroll edge effect(底部不動)。
    func hidesTopEdgeEffect() {
        topEdgeEffect.isHidden = true
    }
}

/// 狀態列高度、由上往下淡出的模糊;減少透明度時是不透明的系統底色。
private struct StatusBarFade: View {
    let reduceTransparency: Bool
    @State private var height: CGFloat = 54

    var body: some View {
        Group {
            if reduceTransparency {
                Rectangle().fill(Color(uiColor: .systemBackground))
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        // 寬度(旋轉、iPad 視窗大小)改變時重量狀態列高度。
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in height = Self.statusBarHeight() }
        .onAppear { height = Self.statusBarHeight() }
    }

    private static func statusBarHeight() -> CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.statusBarManager?.statusBarFrame.height ?? 54
    }
}
#endif
