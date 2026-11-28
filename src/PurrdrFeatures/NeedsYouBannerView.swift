import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 對話頂部的跨聊天「需要你」橫幅(#530、spec #528,設計稿 N4)。
///
/// 在聊天裡時，別的聊天的 Agent 新變成「需要你」就浮出:Agent 頭像加狀態點、「weather-app 需要你」與那個 Agent 最後一段訊息。
/// 點橫幅直接把目前的聊天換成那個聊天(返回回到列表);✕ 或往上滑收起。不計時消失(HIG:少用限時的介面元素);橫幅上不放「›」。
/// 玻璃與狀態橫幅共用 `floatingGlass`(減少透明度時不透明)。
struct NeedsYouBannerView: View {
    @Environment(\.needsYouBanner) private var context

    var body: some View {
        if let context {
            NeedsYouBannerContentView(merged: context.merged, windowChat: context.windowChat, open: context.open)
        }
    }
}

/// 橫幅所需的資料來源與「開啟聊天」動作,由聊天 tab 的根畫面放進環境(Pane 獨立視窗放自己的,#539)。
struct NeedsYouBannerContext {
    let merged: MergedAgentListModel
    /// Pane 獨立視窗自己的聊天(#539):不算在橫幅裡。主視窗是 `nil`(用主視窗的規則)。
    var windowChat: ChatRoute?
    let open: @MainActor (ChatRoute) -> Void
}

extension EnvironmentValues {
    @Entry var needsYouBanner: NeedsYouBannerContext?
}

private struct NeedsYouBannerContentView: View {
    let merged: MergedAgentListModel
    let windowChat: ChatRoute?
    let open: @MainActor (ChatRoute) -> Void

    var body: some View {
        if let content = windowChat.map({ merged.needsYouBanner(forWindow: $0) }) ?? merged.needsYouBanner {
            NeedsYouBannerCard(
                content: content,
                open: { open(content.route) },
                dismiss: { merged.needsYou.dismiss() })
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct NeedsYouBannerCard: View {
    let content: NeedsYouBannerContent
    let open: () -> Void
    let dismiss: () -> Void

    private static let swipeUpDistance: CGFloat = 24

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 12) {
                    AgentStatusAvatar(content: .agent(content.kind), dot: AgentStatus.blocked.statusDot)
                    VStack(alignment: .leading, spacing: 2) {
                        title
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let message = content.message {
                            Text(verbatim: message)
                                .font(.footnote)
                                .foregroundStyle(.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(Text("Opens that chat."))
            .accessibilityIdentifier("needsYou.banner.open")

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
            .accessibilityIdentifier("needsYou.banner.dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .floatingGlass(in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .simultaneousGesture(
            DragGesture(minimumDistance: Self.swipeUpDistance)
                .onEnded { value in
                    if value.translation.height < -Self.swipeUpDistance, abs(value.translation.width) < abs(value.translation.height) { dismiss() }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, dismiss)
        .accessibilityIdentifier("needsYou.banner")
        // 出現時念出來(換成別的聊天也念)。
        .onAppear { announce() }
        .onChange(of: content.route) { announce() }
    }

    /// 第一行完整顯示(放大字級時換行,不截斷);只有一個時「<名稱> 需要你」,多個時帶總數。
    private var titleText: String {
        content.total > 1
            ? String(localized: "\(content.workspace) — \(content.total) chats need you")
            : String(localized: "\(content.workspace) needs you")
    }

    private var title: Text { Text(verbatim: titleText) }

    private var accessibilityLabel: Text {
        Text(verbatim: content.message.map { "\(titleText). \($0)" } ?? titleText)
    }

    private func announce() {
        AccessibilityNotification.Announcement(titleText).post()
    }
}

/// 點橫幅的去向(#546):有主視窗就在主視窗開;沒有就開新的 Pane 視窗。
package enum PaneBannerOpenPlan: Equatable {
    case mainWindow(ChatRoute)
    case newPaneWindow(PaneWindow)

    package static func make(target: ChatRoute, hasMainWindow: Bool, workspaceTitle: String?) -> PaneBannerOpenPlan {
        guard !hasMainWindow else { return .mainWindow(target) }
        return .newPaneWindow(PaneWindow(
            kind: .chat, host: target.host, paneID: target.paneID, sessionID: nil, title: workspaceTitle ?? target.paneID))
    }
}
