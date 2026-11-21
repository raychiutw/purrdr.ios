import PurrdrAgentFeatures
import PurrdrCore
import QuickLook
import SwiftUI

/// 對話畫面(閱讀，行為規格 F5;DESIGN.md 方向 A)。
///
/// - 使用者泡泡右對齊、主色填色;agent 文字不是泡泡，全寬如文件。內容層一律不用 Liquid Glass。
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
    @State private var userIsScrolling = false    /// 使用者在這個列表至少拖動過一次之後才自動翻頁(F5.4:使用者還沒捲之前不可自動翻頁)。
    @State private var userHasDragged = false
    /// 畫面上看得到的列(內容被重建時的錨點,#130)。
    @State private var visibleIDs: [String] = []
    /// 上次看到的列 id(`model.entriesRevision` 改變時與新的比較，#130)。
    @State private var entryIDs: [String] = []
    /// 全螢幕檢視中的泡泡圖片(#37 故事 35)。
    @State private var viewerImage: ViewerImage?
    /// 新訊息與狀態變化的 VoiceOver 公告(有節流，#35)。
    @State private var announcer = ConversationAnnouncer()
    /// 對話的可見高度(扣掉上下 inset;輸入列依它決定鍵盤出現時要不要讓位，#196)。
    /// 放在只有輸入列(聚焦時)讀的 observable 裡：寫進這個畫面的 `@State` 會讓整個對話隨每次捲動量測重畫，
    /// 送出後大量輸出時列表停在一片空白(`testSendingThenLargeOutputKeepsMessagesVisible`)。
    @State private var conversationHeight = ConversationVisibleHeight()

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
                // 標題是 workspace 名稱，副標是狀態與主機名(#270);右邊只有終端機鈕，重新載入改成下拉。
                ToolbarItem(placement: .principal) {
                    ConversationTitleView(title: displayTitle, header: model.statusSummary.header)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let pane = model.agentsPane, !pane.rows.isEmpty {
                    AgentsBarView(pane: pane, readAt: model.agentsPaneReadAt, conversation: model)
                }
            }
            .safeAreaBar(edge: .bottom) { ComposerBar(model: model, conversationHeight: conversationHeight) }
            .forceQuitConfirmation(model: model)
            .secretCheckSheet(model.secretCheck)
            .environment(\.bubbleImages, BubbleImageContext(
                localImage: { [model] in model.localImage(forHostPath: $0) },
                show: { viewerImage = ViewerImage(url: $0) }
            ))
            .imageViewer(item: $viewerImage)
            .environment(\.agentImages, AgentImageContext(loads: model.agentFiles, scope: { [model] in model.fileAccessScope }))
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
            // Send When Done 佇列跟著主機的推送(#305);回到前景時重新讀回。
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                await model.sendWhenDone?.run()
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
        model.statusSummary.header.title.isEmpty ? String(localized: "Chat") : model.statusSummary.header.title
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty && model.pendingItems.isEmpty && model.prompt == nil && model.lastAnswer == nil && model.panel == nil && !model.showsWorkingIndicator {
            // 撐滿可用空間：輸入列(底部的 safeAreaBar)才會貼在畫面底部，不跟著佔位內容置中(#114)。
            placeholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { conversationHeight.update(nil) }
        } else {
            messages
        }
    }

    // MARK: - 訊息

    /// 一個待送項目:依種類用既有的泡泡元件畫(外觀不變，#348 起再統一樣式)。
    @ViewBuilder
    private func pendingRow(_ item: PendingItem) -> some View {
        switch item.kind {
        case .offlineQueued, .offlineProblem:
            if let queued = model.queuedPrompts.first(where: { "queued-\($0.id.uuidString)" == item.id }) {
                QueuedPromptBubbleView(
                    prompt: queued, putBack: { model.putBack(queued.id) }, delete: { model.deleteQueued(queued.id) })
            }
        case .sendWhenDone(let position):
            // 做完再送的佇列是一個元件畫全部項目，只在第一項處畫一次。
            if position == 1, let sendWhenDone = model.sendWhenDone {
                SendWhenDoneQueueView(conversation: model, model: sendWhenDone)
            }
        case .undoCountdown:
            if let undoSend = model.undoSend, let pending = undoSend.pending {
                PendingSendBubbleView(pending: pending, imageCount: model.attachments.count, undo: undoSend.undo, sendNow: undoSend.sendNow)
                    .id(ConversationFollowTarget.pendingSendRowID)
            }
        }
    }

    private var messages: some View {
        // 捲到最底下那一列用 `ScrollViewProxy`:每次呼叫都會捲;`position` 的值沒變時 SwiftUI 不再捲(#191)。
        ScrollViewReader { proxy in
            messageList(proxy)
        }
    }

    private func messageList(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                olderRow
                ForEach(model.visibleEntries) { entry in
                    if let away = model.awaySummary, away.anchorID == entry.id {
                        AwayDividerView(summary: away, isCollapsed: Binding(get: { model.isAwayCollapsed }, set: { model.isAwayCollapsed = $0 }))
                    }
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
                // 待送項目(#347):離線排隊、做完再送、撤回倒數統一從 `pendingItems` 讀，接在最後一則訊息後面。
                ForEach(model.pendingItems) { item in
                    pendingRow(item)
                }
                if let notice = model.sendWhenDone?.notice {
                    ErrorLabel(notice)
                        .font(.footnote)
                        .accessibilityIdentifier("conversation.sendWhenDone.notice")
                }
                // 「需要你」的提示放在最後一則(提問)下方，內容層(F8、HIG 20.7)。
                BlockedPromptView(model: model)
                    .id(ConversationFollowTarget.promptRowID)
                // slash 指令開出的面板(#45):對 herdr 不可見，從畫面讀出後以原生卡片顯示。
                if let panel = model.panel {
                    SlashPanelCard(model: model, panel: panel)
                        .id(ConversationFollowTarget.panelRowID)
                }
                // 即時預覽在列表最底下(工作中狀態在輸入卡片上方的膠囊);agent 停止工作就消失(F5.11)。
                if model.showsWorkingIndicator, model.workingSince != nil {
                    WorkingIndicatorView(preview: model.livePreview)
                        .id(ConversationFollowTarget.workingRowID)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        // 捲動與點訊息區都收起鍵盤(#329);用 simultaneousGesture,連結、卡片與按鈕的點擊照常。
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(TapGesture().onEnded { KeyboardDismissal.dismiss() })
        .onScrollTargetVisibilityChange(idType: String.self) { ids in
            visibleIDs = ids
            scroll.visibleRowsChanged(count: ids.count)
        }
        .defaultScrollAnchor(.bottom)
        // 重新載入、換 session 讀取中:舊訊息留著，頂端只放一條不遮擋的細進度條(#329)。
        .overlay(alignment: .top) {
            if model.isRefreshing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("conversation.refreshing")
            }
        }
        // 下拉重新整理(#270,取代標題列的重新載入鈕):重讀後切回跟隨尾端並捲到底(F5.12)。
        .refreshable {
            await model.reload()
            scroll.jumpToLatest()
            position.scrollTo(edge: .bottom)
        }
        .onScrollPhaseChange { _, phase in
            userIsScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
            if phase == .interacting { userHasDragged = true }
        }
        .onScrollGeometryChange(for: ConversationScrollMetrics.self) { geometry in
            ConversationScrollMetrics(
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height,
                contentOffsetY: geometry.contentOffset.y,
                topInset: geometry.contentInsets.top,
                bottomInset: geometry.contentInsets.bottom
            )
        } action: { _, metrics in
            conversationHeight.update(metrics.containerHeight)
            if userIsScrolling {
                scroll.userScrolled(distanceFromBottom: metrics.distanceFromBottom)
            } else {
                scroll.layoutChanged(distanceFromBottom: metrics.distanceFromBottom)
            }
            // 內容剛被重建、停在內容之外(內容突然縮短)就切回跟隨並捲到底，不留空白;一般排版變化不介入(#130)。
            // 可見範圍小時 LazyVStack 可能停在底部卻一列都沒長出來(#191),同樣再捲一次。
            if !userIsScrolling,
               scroll.returnsToContent(metrics, at: .now) || scroll.refillsVisibleRange(metrics, visibleRows: visibleIDs.count) {
                // 先捲到最後一列(LazyVStack 才排出那一列);同一個排版又停在內容之外時，捲到最後一列多捲了一個底部 inset
                // (可見範圍小、底部 inset 大),改以量到的底部位移再捲一次(#251)。
                let byOffset = scroll.returnsByOffset(metrics)
                scroll.returnedToContent(metrics)
                if byOffset {
                } else {
                    scrollToLastRow(proxy, isNewContent: false)
                }
            }
            // 以位移捲過後 ScrollPosition 停在那個位移、不跟著底部：內容變高(列排出實際高度)或可見範圍變了(停止列、鍵盤)就以新的底部位移再捲(#251)。
            if !userIsScrolling, scroll.followsByOffset(metrics) {
                scroll.followedByOffset(metrics)
                position.scrollTo(y: metrics.bottomScrollPositionY)
            }
            // 距頂端 ≤ 1 個畫面高就讀上一頁。
            if userHasDragged, metrics.distanceFromTop <= metrics.containerHeight, model.older == .available {
                Task { await model.loadOlder() }
            }
        }
        .onAppear { entryIDs = model.entries.map(\.id) }
        // 只有跟隨尾端時 model 才修剪最舊的訊息(#130)。
        .onChange(of: scroll.autoScrollsOnNewContent, initial: true) { model.isFollowingLatest = scroll.autoScrollsOnNewContent }
        .onChange(of: model.entriesRevision) {
            let old = entryIDs
            let new = model.entries.map(\.id)
            entryIDs = new
            scroll.contentChanged(from: old, to: new, at: .now)
            // 閱讀中內容被重建：錨定畫面上第一個仍存在的訊息;都不在就捲到底(#130)。
            let order = Dictionary(old.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let visible = visibleIDs.filter { order[$0] != nil }.sorted { order[$0, default: 0] < order[$1, default: 0] }
            switch scroll.adjustment(from: old, to: new, visible: visible) {
            case .none:
                break
            case .anchor(let id):
                position.scrollTo(id: id, anchor: .top)
            case .bottom:
                scroll.jumpToLatest()
                scrollToLastRow(proxy)
            }
        }
        // 跟隨尾端一律捲到最底下那一列:`scrollTo(edge: .bottom)` 會多捲一個底部 inset,停在內容外成一片空白(#191、#210)。
        .onChange(of: model.entries.last?.id) {
            if scroll.autoScrollsOnNewContent { scrollToLastRow(proxy) }
        }
        .onChange(of: conversationHeight.arrangementRevision) {
            if scroll.autoScrollsOnNewContent { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: model.livePreview) {
            if scroll.autoScrollsOnNewContent { scrollToLastRow(proxy) }
        }
        .onChange(of: model.showsWorkingIndicator) {
            if scroll.autoScrollsOnNewContent { scrollToLastRow(proxy) }
        }
        .onChange(of: model.prompt?.signature) {
            if model.prompt != nil, scroll.autoScrollsOnNewContent { withAnimation(scrollAnimation) { scrollToLastRow(proxy) } }
        }
        .onChange(of: model.panel == nil) {
            if model.panel != nil, scroll.autoScrollsOnNewContent { withAnimation(scrollAnimation) { scrollToLastRow(proxy) } }
        }
        .onChange(of: model.undoSend?.pending == nil) {
            // 倒數中的訊息出現：切到跟隨尾端並捲到它(同回音,F6.5)。
            guard model.undoSend?.pending != nil else { return }
            scroll.jumpToLatest()
            withAnimation(scrollAnimation) { proxy.scrollTo(ConversationFollowTarget.pendingSendRowID, anchor: .bottom) }
        }
        .onChange(of: model.echoes.count) { old, new in
            // 送出前先切到跟隨尾端，讓回音落在視野內(F6.5)。
            guard new > old else { return }
            scroll.jumpToLatest()
            withAnimation(scrollAnimation) { scrollToLastRow(proxy) }
        }
        .overlay(alignment: .bottomTrailing) {
            if scroll.showsJumpToLatest {
                Button {
                    scroll.jumpToLatest()
                    withAnimation(scrollAnimation) { scrollToLastRow(proxy) }
                } label: {
                    Label("Jump to Latest", systemImage: "arrow.down")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .padding()
                .accessibilityIdentifier("conversation.jumpToLatest")            }
        }
    }

    /// 捲到最底下那一列的底部。底部輸入列很高時 `scrollTo(edge: .bottom)` 會多捲一個底部 inset、停在估算高度裡，
    /// 指定列則由 LazyVStack 實際排出那一列(#191)。
    /// `isNewContent`:跟隨新出現的內容(訊息、面板、需要你、工作中指示、回音)時重新計算連續捲回的次數;
    /// 停在內容之外而捲回時不算，否則兩個排版輪流時連續捲回沒有上限(#251)。
    private func scrollToLastRow(_ proxy: ScrollViewProxy, isNewContent: Bool = true) {
        if isNewContent { scroll.followedNewContent() }
        let target = ConversationFollowTarget.target(
            showsWorkingRow: model.showsWorkingIndicator && model.workingSince != nil, showsPanel: model.panel != nil,
            showsPromptCard: model.prompt != nil || model.lastAnswer != nil, lastEntryID: model.entries.last?.id)
        switch target {
        case .row(let id): proxy.scrollTo(id, anchor: .bottom)
        case .bottomEdge: position.scrollTo(edge: .bottom)
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

    /// 沒有快取、也還沒讀到任何訊息時的骨架(#356):三個灰色泡泡，不是整區轉圈(與 Agent 列表的載入骨架同一種 `redacted`)。
    /// 對 VoiceOver 是一個「載入中」的元素。
    private var loadingSkeleton: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { index in
                Text(verbatim: "The latest message from this agent, shown while the conversation loads")
                    .lineLimit(index == 1 ? 1 : 2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: 280, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: index == 1 ? .trailing : .leading)
            }
        }
        .padding(.horizontal, 16)
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading conversation…")
        .accessibilityIdentifier("conversation.loading")
    }

    @ViewBuilder
    private var placeholder: some View {
        switch model.phase {
        case .loading:
            loadingSkeleton
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
        if let banner = model.statusSummary.banner.flatMap(\.transcriptBanner) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.text)
                        // 斷線前在工作：停止列已收起，說明為什麼不能停(#220)。
                        if banner == .offline && model.statusSummary.banner == .offline(needsReconnectToStop: true) {
                            Text("You can stop the agent after reconnecting.")
                        }
                    }
                } icon: {
                    Image(systemName: banner.symbol)
                }
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                Spacer(minLength: 8)
                if banner == .offline {
                    // 中斷標示留在畫面上直到重新連上;也可以手動立刻重試(輪詢本身仍會每幾秒重試)。
                    Button { Task { await model.poll() } } label: {
                        HitTarget("Try Again")
                    }
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

extension ConversationStatusSummary.Banner {
    /// 目前畫面上方橫幅仍只畫對話紀錄與離線(唯讀與主機服務版本各在原處，#348 起併進這條橫幅)。
    var transcriptBanner: ConversationModel.Banner? {
        switch self {
        case .offline: .offline
        case .transcript(let banner): banner
        case .readOnly, .hostServiceUpdateRequired: nil
        }
    }
}

/// 標題列的重新載入(F5.7)。停止與強制結束在輸入卡片的停止列(#220,`StopBar`)。
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
            // skill 名稱用系統綠(實機回報 2026-11-20)。
            CapsuleNote(text: Text("Loaded skill: \(Text(verbatim: skill.name).foregroundStyle(.tint))"), symbol: "book.closed")
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
        case .agentFile(let card) where card.file.isImageFromAgent:
            AgentImageCardView(card: card)
        case .agentFile(let card):
            AgentFileCardView(card: card)
        }
    }
}

/// agent 的訊息。VoiceOver:一則訊息一個元素，開頭念「Agent」(HIG 20.5,#35)。
/// 有程式碼區塊或表格時改成容器：程式碼要能單獨橫捲、複製，表格要能逐格讀，不併成一長串。
///
/// 文字中的主機路徑可點(#229):在 app 內沿用檔案卡片的開啟流程(圖片看大圖、其他用 QuickLook),不交給系統;點之前不讀檔。
struct AgentMessageView: View {
    let text: AgentText
    @Environment(\.agentImages) private var context
    /// 點了的主機路徑：開啟中或開不了時在訊息下方顯示狀態。
    @State private var openedPath: String?
    @State private var previewFile: URL?
    @State private var viewer: AgentImageViewerItem?

    var body: some View {
        let markdown = MarkdownView(text.markdown)
        VStack(alignment: .leading, spacing: 6) {
            markdown
                .accessibilityElement(children: markdown.hasStructuredBlocks || markdown.hasHostPaths ? .contain : .combine)
                .accessibilityLabel { label in
                    Text("Agent:")
                    label
                }
                .accessibilityIdentifier("conversation.agent")
            if let openedPath {
                HostPathOpenStatus(path: openedPath, loads: context.loads) {
                    context.loads?.cancelOpen(openedPath)
                    self.openedPath = nil
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let path = HostPathMention.path(fromLink: url) else { return .systemAction }
            Task { @MainActor in open(path) }
            return .handled
        })
        .quickLookPreview($previewFile)
        .agentImageViewer(item: $viewer)
    }

    private func open(_ path: String) {
        openedPath = path
        guard let loads = context.loads else { return }
        let scope = context.scope()
        Task {
            if HostPathOpenStatus.isImage(path) {
                await loads.load(path, scope: scope, userRequested: true)
                guard case .loaded(let data, _) = loads.states[path] else { return }
                viewer = AgentImageViewerItem(data: data, name: HostPathOpenStatus.name(of: path))
            } else {
                guard let file = await loads.open(path, scope: scope) else { return }
                previewFile = file
            }
            if openedPath == path { openedPath = nil }
        }
    }
}

/// 點了訊息內路徑後的狀態(#229):下載中(可取消)或開不了的原因，文字與檔案卡片相同。
struct HostPathOpenStatus: View {
    let path: String
    let loads: AgentFileLoads?
    let cancel: () -> Void

    static func isImage(_ path: String) -> Bool { AgentFileReference(origin: .readImage, path: path).kind == .image }
    static func name(of path: String) -> String { AgentFileReference(origin: .readImage, path: path).name }

    var body: some View {
        HStack(spacing: 12) {
            if let loads, Self.isImage(path) {
                let state = loads.states[path]
                if let note = AgentImageCardDisplay(state: state).note {
                    noteText(note)
                } else if state == .loading {
                    ProgressView()
                        .accessibilityLabel(Text("Loading image"))
                        .accessibilityIdentifier("conversation.hostPath.progress")
                }
            } else if let loads {
                let display = AgentFileOpenDisplay(state: loads.opens[path])
                if display.isDownloading {
                    Group {
                        if let progress = display.progress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                        }
                    }
                    .accessibilityLabel(Text("Downloading \(Self.name(of: path))"))
                    .accessibilityIdentifier("conversation.hostPath.progress")
                    Button("Cancel", action: cancel)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("conversation.hostPath.cancel")
                } else if let note = display.note {
                    noteText(note)
                }
            } else if let note = AgentFileOpenDisplay(state: .unsupported).note {
                noteText(note)
            }
        }
        .font(.footnote)
    }

    private func noteText(_ note: String) -> some View {
        Text(note)
            .foregroundStyle(.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("conversation.hostPath.note")
    }
}

extension View {
    /// 使用者泡泡的底：系統次要填色、主要色文字(#240);大面積不用主色，agent 與使用者靠位置區分。
    func userBubbleFill() -> some View {
        foregroundStyle(.primary).background(.fill.secondary, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// 使用者泡泡：右對齊、中性填色(`userBubbleFill`)、左側至少留 44pt;agent 與使用者的區分不只靠顏色(位置)。
struct UserBubbleView: View {
    let bubble: UserBubble
    @Environment(\.bubbleImages) private var context

    /// 開頭的 skill／slash 指令用主色(有主機主題時是主題 accent;#329),其餘照泡泡的文字色。
    static func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        if let range = SlashToken.range(in: text),
           let start = AttributedString.Index(range.lowerBound, within: attributed),
           let end = AttributedString.Index(range.upperBound, within: attributed) {
            attributed[start..<end].foregroundColor = Color.commandText
        }
        return attributed
    }

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
                    Text(Self.highlighted(bubble.text))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .userBubbleFill()
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

/// 離開期間的分隔線(#308):「你離開期間 · N 輪 · 工作 M 分鐘」,點一下收合或展開那一段(收合時留最後一句)。
struct AwayDividerView: View {
    let summary: AwaySummary
    @Binding var isCollapsed: Bool

    var body: some View {
        Button {
            withAnimation { isCollapsed.toggle() }
        } label: {
            HStack(spacing: 8) {
                line
                HStack(spacing: 4) {
                    Text(Self.text(summary))
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .accessibilityHidden(true)
                }
                .font(.footnote)
                .foregroundStyle(.secondaryText)
                line
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Self.text(summary)))
        .accessibilityValue(isCollapsed ? Text("Collapsed") : Text("Expanded"))
        .accessibilityHint(isCollapsed ? Text("Shows the messages from while you were away") : Text("Hides the messages from while you were away"))
        .accessibilityIdentifier("conversation.away")
    }

    private var line: some View {
        Rectangle().fill(.separator).frame(height: 1)
    }

    static func text(_ summary: AwaySummary) -> String {
        let turns = String(localized: "\(summary.turns) turns")
        return String(localized: "While you were away · \(turns) · worked \(summary.workMinutes) min")
    }
}

/// 置中的系統註記膠囊。
struct CapsuleNote: View {
    let text: Text
    let symbol: String

    init(text: Text, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    init(text: String, symbol: String) {
        self.init(text: Text(verbatim: text), symbol: symbol)
    }

    var body: some View {
        Label { text } icon: { Image(systemName: symbol) }
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
                // 「✓ Edited N files · N steps」(#271,原型):勾是裝飾，VoiceOver 只念文字。
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondaryText)
                    .accessibilityHidden(true)
                // `Color.secondaryText`(固定色):DisclosureGroup 的 label 是按鈕，階層式 `.secondary` 會變成淡化的 tint、對比不足(#35 audit)。
                Text(run.summary.text(steps: run.steps.count))
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
                    .foregroundStyle(Color.primary)
            }
        case .call(let call):
            if let result = call.result, !result.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    Text(result.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondaryText)
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
                    .foregroundStyle(Color.primary)
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
