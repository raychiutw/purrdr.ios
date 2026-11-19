import SwiftUI

/// 可點列、卡片與縮圖的共用按壓樣式(#234):按下時依 `PressFeedback` 畫中性灰或變暗，不用主色。
struct PressableButtonStyle: ButtonStyle {
    let feedback: PressFeedback
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let highlight = feedback.highlight(isPressed: configuration.isPressed)
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        configuration.label
            .background {
                if highlight == .neutralFillBehind {
                    shape.fill(.fill.tertiary)
                }
            }
            .overlay {
                switch highlight {
                case .neutralFillOver:
                    shape.fill(.fill.tertiary).allowsHitTesting(false)
                case .dimmed(let opacity):
                    shape.fill(.black.opacity(opacity)).allowsHitTesting(false)
                case .neutralFillBehind, nil:
                    EmptyView()
                }
            }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// 本身沒有底色的列：按下時底下畫中性灰。
    static func pressableRow(cornerRadius: CGFloat = 0) -> PressableButtonStyle {
        PressableButtonStyle(feedback: .row, cornerRadius: cornerRadius)
    }

    /// 自己有不透明底的卡片：按下時疊一層中性灰。
    static func pressableCard(cornerRadius: CGFloat) -> PressableButtonStyle {
        PressableButtonStyle(feedback: .card, cornerRadius: cornerRadius)
    }

    /// 圖片縮圖：按下時變暗。
    static func pressableThumbnail(cornerRadius: CGFloat) -> PressableButtonStyle {
        PressableButtonStyle(feedback: .thumbnail, cornerRadius: cornerRadius)
    }
}
