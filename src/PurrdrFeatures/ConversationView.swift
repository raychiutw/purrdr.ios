import PurrdrCore
import SwiftUI

/// 對話畫面(閱讀，行為規格 F5;DESIGN.md 方向 A)。
///
/// - 使用者泡泡右對齊、填色紅底白字;agent 文字不是泡泡，全寬如文件。內容層一律不用 Liquid Glass。
/// - thinking 與工具呼叫收合成一行摘要(DisclosureGroup);呼叫 skill 顯示「Loaded skill: <名稱>」。
/// - 只在使用者位於底部時自動捲到底(`ConversationScroll`)。
/// - 往上捲到接近頂端時載入更早的訊息。
/// - 畫面可見且 app 在前景時才輪詢與回報在場。
/// - 底部是輸入列(`ComposerBar`,功能層 `safeAreaBar`);送出時切回跟隨尾端，讓回音落在視野內。
public struct ConversationView: View {
    let model: ConversationModel
    @Environment(\.scenePhase) private var scenePhase
    /// Reduce Motion:自動捲到底不做動畫，直接跳過去(HIG:減少自動、重複的動畫)。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scroll = ConversationScroll()
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var userIsScrolling = false
    /// 使用者在這個列表至少拖動過一次之後才自動翻頁(F5.4:使用者還沒捲之前不可自動翻頁)。
    @State private var userHasDragged = false
    /// 全螢幕檢視中的泡泡圖片(#37 故事 35)。
    @State private var viewerImage: ViewerImage?
    /// 新訊息與狀態變化的 VoiceOver 公告(有節流，#35)。
    @State private var announcer = ConversationAnnouncer()

    public init(model: ConversationModel) {
        self.model = model
    }

    public var body: some View {
        content
            .navigationTitle(displayTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ConversationTitleView(title: displayTitle, header: model.header)
                }
                if let action = model.headerAction {
                    ToolbarItem(placement: .primaryAction) {
                        HeaderActionButton(model: model, action: action) {
                            // 重新載入後切回跟隨尾端並捲到底(F5.12)。
                            scroll.jumpToLatest()
                            position.scrollTo(edge: .bottom)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let pane = model.agentsPane, !pane.rows.isEmpty {
                    AgentsBarView(pane: pane, readAt: model.agentsPaneReadAt, conversation: model)
                }
            }
            .safeAreaBar(edge: .bottom) { ComposerBar(model: model) }
            .environment(\.bubbleImages, BubbleImageContext(
                localImage: { [model] in model.localImage(forHostPath: $0) },
                show: { viewerImage = ViewerImage(url: $0) }
            ))
            .imageViewer(item: $viewerImage)
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
            .onChange(of: ConversationAnnouncer.Input(items: model.items, status: model.agentStatus, title: displayTitle), initial: true) { _, input in
                announce(announcer.observe(input, now: .now))
            }
            // 節流期間留著的公告：時間到再念。
            .task(id: announcer.pendingDeadline) {
                guard let deadline = announcer.pendingDeadline else { return }
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                announce(announcer.flush(now: .now))
            }
    }

    private var scrollAnimation: Animation? { reduceMotion ? nil : .default }

    private func announce(_ text: String?) {
        guard let text else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    private var displayTitle: String {
        model.title.isEmpty ? String(localized: "Chat") : model.title
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty && model.prompt == nil && model.lastAnswer == nil && model.panel == nil && !model.showsWorkingIndicator {
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
                ForEach(model.entries) { entry in
                    Group {
                        switch entry {
                        case .item(let item):
                            ConversationItemView(item: item)
                        case .echo(let echo):
                            EchoBubbleView(echo: echo) {
                                Task { await model.retry(echoID: echo.id) }
                            }
                        }
                    }
                    .id(entry.id)
                }
                // 「需要你」的提示放在最後一則(提問)下方，內容層(F8、HIG 20.7)。
                BlockedPromptView(model: model)
                    .id("prompt")
                // slash 指令開出的面板(#45):對 herdr 不可見，從畫面讀出後以原生卡片顯示。
                if let panel = model.panel {
                    SlashPanelCard(model: model, panel: panel)
                        .id("panel")
                }
                // 工作中指示在列表最底下;agent 停止工作就消失(F5.11)。
                if model.showsWorkingIndicator, let since = model.workingSince {
                    WorkingIndicatorView(since: since, preview: model.livePreview)
                        .id("working")
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
        .onChange(of: model.entries.last?.id) {
            if scroll.autoScrollsOnNewContent { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: model.livePreview) {
            if scroll.autoScrollsOnNewContent { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: model.prompt?.signature) {
            if model.prompt != nil, scroll.autoScrollsOnNewContent { withAnimation(scrollAnimation) { position.scrollTo(edge: .bottom) } }
        }
        .onChange(of: model.panel == nil) {
            if model.panel != nil, scroll.autoScrollsOnNewContent { withAnimation(scrollAnimation) { position.scrollTo(edge: .bottom) } }
        }
        .onChange(of: model.echoes.count) { old, new in
            // 送出前先切到跟隨尾端，讓回音落在視野內(F6.5)。
            guard new > old else { return }
            scroll.jumpToLatest()
            withAnimation(scrollAnimation) { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if scroll.showsJumpToLatest {
                Button {
                    scroll.jumpToLatest()
                    withAnimation(scrollAnimation) { position.scrollTo(edge: .bottom) }
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
                .foregroundStyle(.secondaryText)
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
                if model.agentKind == "codex" {
                    Text("Codex reports its session after you send the first message. Its messages appear here once it does.")
                } else {
                    Text("The agent hasn’t reported which session it’s in yet. Its messages appear here once it does.")
                }
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
            HStack {
                Label(banner.text, systemImage: banner.symbol)
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                Spacer(minLength: 8)
                if banner == .offline {
                    // 中斷標示留在畫面上直到重新連上;也可以手動立刻重試(輪詢本身仍會每幾秒重試)。
                    Button("Try Again") { Task { await model.poll() } }
                        .font(.footnote)
                        .accessibilityIdentifier("conversation.retry")
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("conversation.banner")
        }
    }
}

/// 標題列的動作鈕(F5.7、F6.7):不在工作中「重新載入」;工作中「停止」——點一下送一個 Esc,
/// 長按打開選單，選「強制結束」才送 Ctrl-C(選單本身就是說明與確認)。「需要你」的 agent 永不中斷(model 與核心都擋)。
private struct HeaderActionButton: View {
    let model: ConversationModel
    let action: HeaderAction
    let didReload: () -> Void

    var body: some View {
        switch action {
        case .reload:
            Button {
                Task {
                    await model.reload()
                    didReload()
                }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("conversation.reload")
        case .stop:
            Menu {
                Section {
                    Button("Force Quit Agent", systemImage: "xmark.octagon", role: .destructive) {
                        Task { await model.forceQuit() }
                    }
                    .accessibilityIdentifier("conversation.forceQuit")
                } header: {
                    Text("Control-C may end the agent process and this session. The conversation stays on the host, but the agent stops. Stop only interrupts the current turn.")
                        .foregroundStyle(.secondaryText)
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            } primaryAction: {
                Task { await model.stop() }
            }
            .disabled(model.isStopping)
            .accessibilityHint(Text("Interrupts the agent’s current turn. Press and hold to force quit."))
            .accessibilityIdentifier("conversation.stop")
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
        case .ambiguous: "More than one transcript matches this chat’s session, so none is shown."
        case .compressed: "Codex compressed this chat’s transcript, so it can’t be shown here. Open the chat on the host to see it."
        }
    }

    var symbol: String {
        switch self {
        case .offline: "wifi.slash"
        case .unreadable: "lock"
        case .readFailed: "arrow.clockwise"
        case .ambiguous: "questionmark.folder"
        case .compressed: "archivebox"
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
            AgentMessageView(text: text)
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
        case .shell(let run):
            ShellRunView(run: run)
        }
    }
}

/// agent 的訊息。VoiceOver:一則訊息一個元素，開頭念「Agent」(HIG 20.5,#35)。
/// 有程式碼區塊或表格時改成容器：程式碼要能單獨橫捲、複製，表格要能逐格讀，不併成一長串。
struct AgentMessageView: View {
    let text: AgentText

    var body: some View {
        let markdown = MarkdownView(text.markdown)
        markdown
            .accessibilityElement(children: markdown.hasStructuredBlocks ? .contain : .combine)
            .accessibilityLabel { label in
                Text("Agent:")
                label
            }
            .accessibilityIdentifier("conversation.agent")
    }
}

/// 使用者泡泡：右對齊、紅底填色(`hostFill`,白字 ≥ 4.5:1)、左側至少留 44pt;agent 與使用者的區分不只靠顏色(位置)。
struct UserBubbleView: View {
    let bubble: UserBubble
    @Environment(\.bubbleImages) private var context

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 4) {
                if bubble.imageCount > 0 {
                    // 主機路徑依檔名找手機上的副本;路徑數不足(例如只有圖片區塊)的部分顯示「Image」標籤。
                    let known = bubble.imagePaths.map { context.localImage($0) }
                    BubbleImagesView(images: known + Array(repeating: nil, count: max(0, bubble.imageCount - known.count)))
                }
                if !bubble.text.isEmpty {
                    Text(bubble.text)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .hostFill(in: RoundedRectangle(cornerRadius: 18))
                }
                if let date = bubble.date {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        // VoiceOver:一則訊息一個元素(HIG 20.5,#35)。有圖片時圖片可點開，泡泡改成容器。
        // 合併後念「Your message.」+ 內容 + 時間(作者、內容、時間一次念完)。
        .accessibilityElement(children: bubble.imageCount > 0 ? .contain : .combine)
        .accessibilityLabel { label in
            Text("Your message.")
            label
        }
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
            .foregroundStyle(.secondaryText)
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
                // `Color.secondaryText`(固定色):DisclosureGroup 的 label 是按鈕，階層式 `.secondary` 會變成淡化的 tint、對比不足(#35 audit)。
                Text(run.summary.text)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
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
                    .foregroundStyle(.secondaryText)
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
                        .foregroundStyle(call.isError ? AnyShapeStyle(.errorText) : AnyShapeStyle(.secondaryText))
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
                        .foregroundStyle(Color.secondaryText)
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
