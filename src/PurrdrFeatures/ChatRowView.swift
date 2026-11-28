import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 共用聊天列(#502,設計稿 A 寬鬆版「郵件式三層」):Spaces 的 Tab 列與載入骨架(#496)都用它。
///
/// 左邊是 48pt 頭像(垂直置中於文字內容高度,右下角四色狀態圓點),中間三行(Tab 名稱 17pt Semibold、session 標題、預覽),
/// 右邊是時間與用量環。輔助使用字級時右欄堆到文字下方。內容在 `ChatRowContent`,這裡只有版面。
/// 列的上下內距由使用端的 `listRowInsets`(`ChatRowView.rowInsets`)給,頭像才能對齊文字內容、不含內距。
struct ChatRowView: View {
    let content: ChatRowContent
    /// 「需要你」段落裡最新轉變那一列尾端的「剛剛」(#531);其他列 `nil`。
    var justNowText: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var tabNameSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var previewSize: CGFloat = 14

    /// 設計稿標註:上內距 14、下內距 16、左右 16。
    static let rowInsets = EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16)

    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }
    private var lineLimit: Int? { ChatRowContent.lineLimit(accessibilitySize: isStacked) }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AgentStatusAvatar(content: avatarContent, dot: content.statusDot)
            if isStacked {
                VStack(alignment: .leading, spacing: 14) {
                    textBlock
                    trailingColumn
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    textBlock
                    Spacer(minLength: 0)
                    trailingColumn
                }
            }
        }
    }

    private var avatarContent: AgentStatusAvatar.Content {
        switch content.avatar {
        case .agent(let kind): .agent(AgentID(herdrName: kind))
        case .terminal: .terminal
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: ChatRowContent.Line) -> some View {
        switch line {
        case .title(let text):
            // 按鈕列的 label 會被 tint 染成主色;`.primary` 在按鈕裡解析成 tint,要用 `Color.primary`。
            Text(verbatim: text)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: isStacked)
        case .detail(let badge, let sessionTitle):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let badge {
                    Text(verbatim: badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 6)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                if let sessionTitle {
                    Text(verbatim: sessionTitle)
                        .font(.system(size: tabNameSize, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: isStacked)
                        .accessibilityIdentifier("chatRow.sessionTitle")
                }
            }
        case .preview(let text):
            Text(verbatim: text)
                .font(.system(size: previewSize))
                .foregroundStyle(Color.secondaryText)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: isStacked)
        }
    }

    /// 右欄:時間,下方是用量環與百分比(對 VoiceOver 隱藏,念在列的句子裡)。
    @ViewBuilder
    private var trailingColumn: some View {
        if content.time != nil || content.contextPercent != nil || justNowText != nil {
            let layout = isStacked ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
            layout {
                if let justNowText {
                    Text(verbatim: justNowText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 8)
                        .background(Color.orange.opacity(0.3), in: Capsule())
                        .accessibilityIdentifier("chatRow.justNow")
                }
                if let time = content.time {
                    Text(time.text())
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryText)
                }
                if let percent = content.contextPercent {
                    ContextMeter(percent: percent)
                }
            }
            .frame(minWidth: isStacked ? nil : 58, alignment: isStacked ? .leading : .trailing)
        }
    }

    /// VoiceOver 句子:Tab 名稱、session 標題、種類、狀態、離開期間、預覽、時間、用量。狀態圓點不另成元素,由這句念出。
    static func accessibilityText(_ tab: SpacesTab, justNow: Bool = false) -> String {
        let first = tab.tabName ?? tab.contentTitle
        var parts: [String?] = [first, first == tab.contentTitle ? nil : tab.contentTitle]
        switch tab.avatar {
        case .agent(let kind, let status):
            parts += [AgentID(herdrName: kind).displayName, String(localized: status.title)]
        case .terminal:
            parts += [String(localized: "Terminal")]
        }
        if let agent = tab.agent {
            parts += [
                agent.isAway ? String(localized: "New since you were away") : nil,
                ChatRowContent.previewText(agent.preview), agent.time?.text(),
                agent.progress?.contextPercent.map { String(localized: "Context \($0)%") },
            ]
        }
        if justNow { parts.append(NeedsYouSection.justNowText) }
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

extension ChatRowContent {
    /// 骨架畫面(#496)的佔位列內容:假資料撐出同樣的三行與右欄,`.skeleton` 畫成灰塊。
    static func placeholder(_ index: Int) -> ChatRowContent {
        ChatRowContent(tab: SpacesTab(
            host: .demo, key: "placeholder-\(index)", title: "Agent name placeholder",
            target: .pane(ChatRoute(host: .demo, paneID: "placeholder-\(index)")), avatar: .agent(kind: AgentID.claude.canonicalName, status: .idle),
            tabName: "Tab name",
            agent: AgentRow(
                paneID: "placeholder-\(index)", title: "Agent name placeholder", subtitle: "",
                preview: .message("The latest message from this agent", fromYou: false), time: .now, status: .idle,
                progress: AgentProgress(contextPercent: 50))))
    }
}
