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
///
/// 以 UIKit 視圖畫(`TopFadeView`),不用 SwiftUI 的 `Rectangle().fill(.material)`:頁面外層常掛 `accessibilityIdentifier`
/// (例:`sheet.account`),SwiftUI 會把外層的 identifier 套到疊在裡面的每個節點,淡模糊就成了第二個同名元素,
/// UI 測試的 `firstMatch` 抓到 54pt 高的細條、捲不動(#683 造成)。`TopFadeView` 不接受 identifier、也不是 accessibility 元素,
/// 一次解掉所有頁面,不必逐頁調整 identifier 的順序。
private struct StatusBarFade: View {
    let reduceTransparency: Bool
    @State private var height: CGFloat = StatusBarHeight.fallback

    var body: some View {
        TopFadeRepresentable(reduceTransparency: reduceTransparency, onStatusBarHeight: { height = StatusBarHeight.resolve(sceneHeight: $0) })
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

private struct TopFadeRepresentable: UIViewRepresentable {
    let reduceTransparency: Bool
    let onStatusBarHeight: (CGFloat?) -> Void

    func makeUIView(context: Context) -> TopFadeView {
        TopFadeView()
    }

    func updateUIView(_ view: TopFadeView, context: Context) {
        view.reduceTransparency = reduceTransparency
        view.onStatusBarHeight = onStatusBarHeight
    }
}

/// 由上往下淡出的模糊視圖:不是 accessibility 元素,且忽略外層套下來的 identifier。
final class TopFadeView: UIVisualEffectView {
    private let fadeMask = CAGradientLayer()
    private var reportedHeight: CGFloat?

    /// 回報這個視圖所在視窗場景的狀態列高度(換視窗、旋轉、iPad 視窗大小改變時重報);
    /// 延後到這次排版之後再通知,不在 layoutSubviews 內改 SwiftUI 狀態。
    var onStatusBarHeight: ((CGFloat?) -> Void)? {
        didSet { reportStatusBarHeight(force: true) }
    }

    var reduceTransparency = false {
        didSet { applyStyle() }
    }

    init() {
        super.init(effect: nil)
        isUserInteractionEnabled = false
        fadeMask.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        applyStyle()
    }

    required init?(coder: NSCoder) { nil }

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override var accessibilityElementsHidden: Bool {
        get { true }
        set {}
    }

    override var accessibilityIdentifier: String? {
        get { nil }
        set {}
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fadeMask.frame = bounds
        reportStatusBarHeight(force: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportStatusBarHeight(force: true)
    }

    private func reportStatusBarHeight(force: Bool) {
        let height = window?.windowScene?.statusBarManager?.statusBarFrame.height
        guard force || height != reportedHeight else { return }
        reportedHeight = height
        guard let callback = onStatusBarHeight else { return }
        DispatchQueue.main.async { callback(height) }
    }

    private func applyStyle() {
        if reduceTransparency {
            effect = nil
            backgroundColor = .systemBackground
            layer.mask = nil
        } else {
            effect = UIBlurEffect(style: .systemUltraThinMaterial)
            backgroundColor = nil
            layer.mask = fadeMask
        }
    }
}
#endif
