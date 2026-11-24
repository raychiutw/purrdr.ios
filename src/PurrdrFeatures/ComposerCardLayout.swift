import PurrdrAgentFeatures
import SwiftUI

/// 輸入卡片裡各元件的角色(`ComposerCardLayout` 依角色擺位)。
enum ComposerCardRole: Hashable {
    case attach
    case editor
    case model
    case send
}

struct ComposerCardRoleKey: LayoutValueKey {
    static let defaultValue = ComposerCardRole.editor
}

extension View {
    func composerCardRole(_ role: ComposerCardRole) -> some View {
        layoutValue(key: ComposerCardRoleKey.self, value: role)
    }
}

/// 輸入卡片的版面(#382):同一組子視圖在兩態間換位置,輸入框不重建(聚焦與組字不中斷)。
///
/// - 收合:一列,左「+」、中間輸入框、右送出。
/// - 展開:上方輸入框(整寬),下方一列 +、模型膠囊、(空白)、送出。模型膠囊以理想寬度排,不被截斷。
struct ComposerCardLayout: Layout {
    var form: ComposerForm

    /// 觸控目標(「+」與送出)。
    static let control: CGFloat = 44
    static let gap: CGFloat = 4
    static let sideInset: CGFloat = 6
    static let editorInset: CGFloat = 4

    private func subview(_ role: ComposerCardRole, in subviews: Subviews) -> LayoutSubview? {
        subviews.first { $0[ComposerCardRoleKey.self] == role }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        guard let editor = subview(.editor, in: subviews) else { return CGSize(width: width, height: Self.control) }
        switch form {
        case .collapsed:
            let editorWidth = collapsedEditorWidth(width, subviews)
            let height = editor.sizeThatFits(ProposedViewSize(width: editorWidth, height: proposal.height)).height
            return CGSize(width: width, height: max(Self.control, height))
        case .expanded:
            let editorProposalHeight = proposal.height.map { max(0, $0 - Self.expandedChrome) }
            let height = editor.sizeThatFits(ProposedViewSize(width: width - 2 * Self.editorInset, height: editorProposalHeight)).height
            return CGSize(width: width, height: Self.editorInset + height + Self.control + Self.sideInset)
        }
    }

    /// 展開時輸入框以外的高度(上內距 + 按鈕列 + 下內距)。
    private static var expandedChrome: CGFloat { editorInset + control + sideInset }

    private func collapsedEditorWidth(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        let controls = (subview(.attach, in: subviews) == nil ? 0 : Self.control + Self.gap) + Self.control + Self.gap
        return max(0, width - 2 * Self.sideInset - controls)
    }

    /// 收合的輸入框比展開的窄多少(輸入框以收合時的寬度量行數，#512)。
    static func collapsedWidthReduction(hasAttach: Bool) -> CGFloat {
        let controls = (hasAttach ? control + gap : 0) + control + gap
        return 2 * sideInset + controls - 2 * editorInset
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let attach = subview(.attach, in: subviews)
        let editor = subview(.editor, in: subviews)
        let model = subview(.model, in: subviews)
        let send = subview(.send, in: subviews)
        let controlSize = ProposedViewSize(width: Self.control, height: Self.control)
        switch form {
        case .collapsed:
            var x = bounds.minX + Self.sideInset
            if let attach {
                attach.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: controlSize)
                x += Self.control + Self.gap
            }
            let editorWidth = collapsedEditorWidth(bounds.width, subviews)
            editor?.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: editorWidth, height: bounds.height))
            send?.place(at: CGPoint(x: bounds.maxX - Self.sideInset, y: bounds.midY), anchor: .trailing, proposal: controlSize)
        case .expanded:
            let editorHeight = max(0, bounds.height - Self.expandedChrome)
            editor?.place(
                at: CGPoint(x: bounds.minX + Self.editorInset, y: bounds.minY + Self.editorInset), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width - 2 * Self.editorInset, height: editorHeight))
            let rowY = bounds.maxY - Self.sideInset - Self.control / 2
            var x = bounds.minX + Self.sideInset
            if let attach {
                attach.place(at: CGPoint(x: x, y: rowY), anchor: .leading, proposal: controlSize)
                x += Self.control + Self.gap
            }
            if let model {
                let available = max(0, bounds.maxX - Self.sideInset - Self.control - Self.gap - x)
                let ideal = model.sizeThatFits(.unspecified).width
                model.place(at: CGPoint(x: x, y: rowY), anchor: .leading, proposal: ProposedViewSize(width: min(ideal, available), height: Self.control))
            }
            send?.place(at: CGPoint(x: bounds.maxX - Self.sideInset, y: rowY), anchor: .trailing, proposal: controlSize)
        }
    }
}
