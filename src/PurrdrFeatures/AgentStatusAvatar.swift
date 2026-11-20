import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 列首頭像加右下角狀態(#316):Agents 與 Spaces 兩個檢視共用。
///
/// 狀態沿用 `AgentStatus.symbol`(形狀＋顏色，不只靠顏色;實心＝未讀、空心＝已讀),
/// 底下墊一圈列背景色，疊在頭像外緣。狀態由列的 VoiceOver 句子念，這裡不另成元素。
struct AgentStatusAvatar: View {
    enum Content {
        case agent(AgentKind)
        case terminal
    }

    let content: Content
    /// 沒有值時不畫狀態(只有終端機的 Tab)。
    let status: AgentStatus?

    var body: some View {
        avatar
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    StatusBadge(status: status)
                        .offset(x: 4, y: 4)
                }
            }
            // 狀態超出頭像外緣，列的排版要把它算進去。
            .padding(.trailing, 4)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatar: some View {
        switch content {
        case .agent(let kind):
            AgentKindAvatar(kind: kind)
        case .terminal:
            TerminalAvatar()
        }
    }
}

/// 狀態符號：列背景色的圓底，裡面是狀態的形狀與顏色。
private struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(status.tone.style)
            .frame(width: 14, height: 14)
            .padding(2)
            .background(.listRowSurface, in: Circle())
            // 頭像固定大小，狀態跟著頭像，不隨字級放大。
            .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

/// 只有終端機的 Tab:中性底色的終端機符號，大小與 Agent 種類頭像相同。
private struct TerminalAvatar: View {
    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(AgentKindAvatarStyle(kind: .unknown("")).palette.color))
    }
}

extension ShapeStyle where Self == Color {
    /// `insetGrouped` 列表的列底色(狀態符號的圓底，跟列背景融在一起)。
    static var listRowSurface: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}
