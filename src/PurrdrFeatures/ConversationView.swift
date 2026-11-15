import PurrdrCore
import SwiftUI

/// 對話畫面(閱讀，行為規格 F5;DESIGN.md 方向 A)。
///
/// - 使用者泡泡右對齊、填色紅底白字;agent 文字不是泡泡，全寬如文件。內容層一律不用 Liquid Glass。
/// - thinking 與工具呼叫收合成一行摘要(DisclosureGroup);呼叫 skill 顯示「Loaded skill: <名稱>」。
/// - 只在使用者位於底部時自動捲到底(`ConversationScroll`)。
/// - 往上捲到接近頂端時載入更早的訊息。
/// - 畫面可見且 app 在前景時才輪詢與回報在場。
public struct ConversationView: View {
    let model: ConversationModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var scroll = ConversationScroll()
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var userIsScrolling = false
    /// 使用者在這個列表至少拖動過一次之後才自動翻頁(F5.4:使用者還沒捲之前不可自動翻頁)。
    @State private var userHasDragged = false

    public init(model: ConversationModel) {
        self.model = model
    }

    public var body: some View {
        content
            .navigationTitle(model.title.isEmpty ? String(localized: "Chat") : model.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let pane = model.agentsPane, !pane.rows.isEmpty {
                    AgentsBarView(pane: pane, readAt: model.agentsPaneReadAt, conversation: model)
                }
            }
            .environment(\.delegationContext, DelegationContext(
                workflowModel: { [model] in model.workflowModel(for: $0) },
                canOpen: { [model] in model.canOpen($0) }
            ))
            .navigationDestination(for: DelegationRoute.self) { [model] route in
                DelegationDestination(route: route, conversation: model)
            }
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                await model.run()
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            placeholder
        } else {
            messages
        }
    }

    // MARK: - 訊息

    private var messages: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                olderRow
                ForEach(model.items) { item in
                    ConversationItemView(item: item)
                        .id(item.id)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollPhaseChange { _, phase in
            userIsScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
            if phase == .interacting { userHasDragged = true }
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                distanceFromBottom: geometry.contentSize.height + geometry.contentInsets.bottom
                    - geometry.containerSize.height - geometry.contentOffset.y,
                distanceFromTop: geometry.contentOffset.y + geometry.contentInsets.top,
                viewportHeight: geometry.containerSize.height
            )
        } action: { _, metrics in
            if userIsScrolling {
                scroll.userScrolled(distanceFromBottom: metrics.distanceFromBottom)
            } else {
                scroll.layoutChanged(distanceFromBottom: metrics.distanceFromBottom)
            }
            // 距頂端 ≤ 1 個畫面高就讀上一頁。
            if userHasDragged, metrics.distanceFromTop <= metrics.viewportHeight, model.older == .available {
                Task { await model.loadOlder() }
            }
        }
        .onChange(of: model.items.last?.id) {
            if scroll.autoScrollsOnNewContent { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if scroll.showsJumpToLatest {
                Button {
                    scroll.jumpToLatest()
                    withAnimation { position.scrollTo(edge: .bottom) }
                } label: {
                    Label("Jump to Latest", systemImage: "arrow.down")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .padding()
                .accessibilityIdentifier("conversation.jumpToLatest")
            }
        }
    }

    /// 頂端固定一列：載入中轉圈／「對話開頭」／空白(保持底部錨定穩定)。
    @ViewBuilder
    private var olderRow: some View {
        switch model.older {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .reachedStart:
            Text("Beginning of conversation")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("conversation.beginning")
        case .available:
            Color.clear.frame(height: 1)
        }
    }

    // MARK: - 佔位與標示

    @ViewBuilder
    private var placeholder: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading conversation…")
        case .waitingForSession:
            ContentUnavailableView {
                Label("Waiting for the Session", systemImage: "hourglass")
            } description: {
                Text("The agent hasn’t reported which session it’s in yet. Its messages appear here once it does.")
            }
        case .missingSession:
            ContentUnavailableView {
                Label("Can’t Identify This Chat", systemImage: "questionmark.bubble")
            } description: {
                Text("The agent didn’t report its session, so its messages can’t be told apart from other chats in the same folder. Make sure the herdr integration for this agent is installed; it reports the session when one starts.")
            }
        case .unsupported:
            ContentUnavailableView {
                Label("Chat History Isn’t Available", systemImage: "terminal")
            } description: {
                Text("This agent’s transcript can’t be read yet. Use the host’s terminal to see it.")
            }
        case .agentGone:
            ContentUnavailableView {
                Label("Agent Ended", systemImage: "xmark.bubble")
            } description: {
                Text("This pane no longer has an agent running.")
            }
        case .ready:
            ContentUnavailableView {
                Label("No Messages Yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(model.agentStatus == .working ? "The agent is working. Its reply will appear here." : "Messages in this chat appear here.")
            }
        }
    }

    /// 非干擾式標示：不在進入畫面時跳 alert,也不只用自動消失的 toast(HIG 20.5)。
    @ViewBuilder
    private var banner: some View {
        if let banner = model.banner {
            Label(banner.text, systemImage: banner.symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("conversation.banner")
        }
    }
}

private struct ScrollMetrics: Equatable {
    var distanceFromBottom: Double
    var distanceFromTop: Double
    var viewportHeight: Double
}

extension ConversationModel.Banner {
    var text: LocalizedStringKey {
        switch self {
        case .offline: "Offline — showing the last loaded conversation."
        case .unreadable: "Can’t read this chat’s transcript on the host. Check the file’s permissions."
        case .readFailed: "Couldn’t update the conversation. Retrying…"
        }
    }

    var symbol: String {
        switch self {
        case .offline: "wifi.slash"
        case .unreadable: "lock"
        case .readFailed: "arrow.clockwise"
        }
    }
}

// MARK: - 項目

struct ConversationItemView: View {
    let item: ConversationItem

    var body: some View {
        switch item {
        case .user(let bubble):
            UserBubbleView(bubble: bubble)
        case .agentText(let text):
            MarkdownView(text.markdown)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Agent message"))
                .accessibilityIdentifier("conversation.agent")
        case .toolRun(let run):
            ToolRunView(run: run)
        case .skill(let skill):
            CapsuleNote(text: String(localized: "Loaded skill: \(skill.name)"), symbol: "book.closed")
                .accessibilityIdentifier("conversation.skill")
        case .note(let note):
            CapsuleNote(text: note.text, symbol: "info.circle")
                .accessibilityIdentifier("conversation.note")
        case .subagent(let card):
            SubagentCardView(card: card)
        case .workflow(let card):
            WorkflowCardView(card: card)
        }
    }
}

/// 使用者泡泡：右對齊、tint 填色(#D91E36 配白字 5.0:1)、左側至少留 44pt;agent 與使用者的區分不只靠顏色(位置)。
struct UserBubbleView: View {
    let bubble: UserBubble

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 4) {
                Text(bubble.text)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                if bubble.imageCount > 0 {
                    Label("\(bubble.imageCount) images", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let date = bubble.date {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Your message. \(bubble.text)"))
        .accessibilityIdentifier("conversation.user")
    }
}

/// 置中的系統註記膠囊。
struct CapsuleNote: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.tertiary, in: Capsule())
            .frame(maxWidth: .infinity)
    }
}

/// 工具串：預設收合成一行摘要;有失敗時摘要旁有紅點。展開後每個呼叫一列，有結果者可再展開看結果(最多 12 行)。
struct ToolRunView: View {
    let run: ToolRun
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(run.steps) { step in
                    ToolStepView(step: step)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text(run.summary.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if run.summary.failures > 0 {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityIdentifier("conversation.toolRun")
    }
}

struct ToolStepView: View {
    let step: ToolStep
    @State private var expanded = false

    var body: some View {
        switch step.kind {
        case .thinking(let text):
            DisclosureGroup(isExpanded: $expanded) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(.subheadline)
            }
        case .call(let call):
            if let result = call.result, !result.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    Text(result.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(call.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    callLabel(call)
                }
            } else {
                callLabel(call)
            }
        }
    }

    private func callLabel(_ call: ToolCallStep) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(call.name)
                    .font(.subheadline)
                if !call.input.isEmpty {
                    Text(call.input)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: call.isError ? "exclamationmark.triangle" : call.category.symbol)
                .foregroundStyle(call.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
    }
}

extension ToolCategory {
    var symbol: String {
        switch self {
        case .command: "terminal"
        case .edit: "pencil"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .fetch: "globe"
        case .todo: "checklist"
        case .question: "questionmark.bubble"
        case .agent: "person.2"
        case .other: "wrench.and.screwdriver"
        }
    }
}
