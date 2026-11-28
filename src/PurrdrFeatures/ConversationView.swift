import PurrdrAgentFeatures
import PurrdrCore
import QuickLook
import SwiftUI

/// 對話畫面(閱讀，行為規格 F5;DESIGN.md 方向 A)。
///
/// - 使用者泡泡右對齊、主色填色;agent 文字不是泡泡，全寬如文件。內容層一律不用 Liquid Glass。
/// - thinking 與工具呼叫收合成一行摘要(DisclosureGroup);呼叫 skill 顯示「Loaded skill: <名稱>」。
/// - 列表是 `UICollectionView`(`ChatListView`),只在使用者位於底部時自動捲到底(捲動決策者,ADR-0014)。
/// - 往上捲到接近頂端時載入更早的訊息。
/// - 畫面可見且 app 在前景時才輪詢與回報在場。
/// - 底部是輸入列(`ComposerBar`,功能層 `safeAreaBar`);送出時切回跟隨尾端，讓回音落在視野內。
public struct ConversationView: View {
    @Bindable var model: ConversationModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.hitchRecorder) private var hitchRecorder
    @Environment(\.tracksReadingDrift) private var tracksReadingDrift
    @Environment(\.hostTheme) private var hostTheme
    /// 列表的呼叫口(「跳到最新」、輸入列重排)與最近量到的可見高度。
    @State private var listHandle = ChatListHandle()
    /// 「跳到最新」是否已顯示(跟隨中延遲顯示,#476)。
    @State private var jumpToLatestVisible = false
    /// 列表量到離底超過門檻(只在跨過門檻時才寫入,不隨每次捲動重畫)。
    @State private var isAwayFromBottom = false
    /// 全螢幕檢視中的泡泡圖片(#37 故事 35)。
    @State private var viewerItem: ImageViewerItem?
    /// 列內要呈現的預覽、sheet 與導覽:列嵌在 `UIHostingConfiguration` 裡沒有可靠的呈現者,改由這個畫面呈現(`ConversationPresenter`)。
    @State private var previewFile: URL?
    @State private var presentedSheet: ConversationSheetContent?
    @State private var openedRoute: DelegationRoute?
    /// 新訊息與狀態變化的 VoiceOver 公告(有節流，#35)。
    /// 對話的可見高度(扣掉上下 inset;輸入列依它決定鍵盤出現時要不要讓位，#196)。
    /// 放在只有輸入列(聚焦時)讀的 observable 裡：寫進這個畫面的 `@State` 會讓整個對話隨每次捲動量測重畫，
    /// 送出後大量輸出時列表停在一片空白(`testSendingThenLargeOutputKeepsMessagesVisible`)。
    @State private var conversationHeight = ConversationVisibleHeight()
    /// 避開玻璃導覽列、橫幅與輸入列後的安全區域框(全域座標),列表據此算上下 inset。
    @State private var safeAreaFrame: CGRect = .zero


    public init(model: ConversationModel) {
        self.model = model
    }

    public var body: some View {
        content
            .appPageTopEdge()
            .modifier(ConversationNavigationTitle(model: model))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaBar(edge: .top) {
                // 狀態橫幅(斷線等)在上、跨聊天「需要你」橫幅在它下面(#530),兩者上下排列不互相蓋住。
                VStack(spacing: 0) {
                    ConversationBannerView(model: model)
                    NeedsYouBannerView()
                }
            }
            .safeAreaBar(edge: .bottom) { ComposerBar(model: model, conversationHeight: conversationHeight) }
            .secretCheckSheet(model.secretCheck)
            .environment(\.bubbleImages, BubbleImageContext(
                localImage: { [model] in model.localImage(forHostPath: $0) },
                show: { viewerItem = $0 }
            ))
            .environment(\.inlineSlashNames, model.inlineSlashNames)
            .imageViewer(item: $viewerItem)
            .quickLookPreview($previewFile)
            .sheet(item: $presentedSheet) { $0.content }
            .navigationDestination(item: $openedRoute) { [model] route in
                DelegationDestination(route: route, conversation: model)
            }
            .environment(\.agentImages, AgentImageContext(
                loads: model.agentFiles, scope: { [model] in model.fileAccessScope }, isAnchored: { [model] in model.hasFileAccessAnchor }))
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
            // 離開期間摘要(#308):app 進背景再回來也算離開。
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.scenePhaseChanged(isBackground: true) }
                if phase == .active { model.scenePhaseChanged(isBackground: false) }
            }
            // Send When Done 佇列跟著主機的推送(#305);回到前景時重新讀回。
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                await model.sendWhenDone?.run()
            }
            .modifier(ConversationAnnouncement(model: model))
    }

    private var content: some View {
        chatList
            .overlay {
                if isEmptyState {
                    // 撐滿可用空間：輸入列(底部的 safeAreaBar)才會貼在畫面底部，不跟著佔位內容置中(#114)。
                    placeholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: isEmptyState) { _, isEmpty in
                conversationHeight.update(isEmpty ? nil : listHandle.visibleHeight)
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
            }
        }
    }

    /// 這個待送項目有沒有東西可畫(列表不放空列,不然列間距會多出一段)。
    private var isEmptyState: Bool { ConversationListContentBuilder.isEmptyState(model) }

    private var listContent: ChatListContent { ConversationListContentBuilder.make(model) }

    /// 一列的畫面。列嵌在 `UIHostingConfiguration` 裡,看不到這個畫面的環境值,所以這裡重新注入列需要的那幾個。
    private func rowView(_ rowContent: ChatListRowContent) -> AnyView {
        AnyView(
            rowBody(rowContent)
                // 每一列以自己的 id 當 SwiftUI 身分:cell 重用時 hosted view 不會把某個 view 的 @State 帶到別列。
                .id(rowContent.rowID)
                .environment(\.bubbleImages, BubbleImageContext(
                    localImage: { [model] in model.localImage(forHostPath: $0) },
                    show: { viewerItem = $0 }
                ))
                .environment(\.inlineSlashNames, model.inlineSlashNames)
                .environment(\.agentImages, AgentImageContext(
                    loads: model.agentFiles, scope: { [model] in model.fileAccessScope }, isAnchored: { [model] in model.hasFileAccessAnchor }))
                .environment(\.delegationContext, DelegationContext(
                    workflowModel: { [model] in model.workflowModel(for: $0) },
                    canOpen: { [model] in model.canOpen($0) }
                ))
                .environment(\.conversationPresenter, ConversationPresenter(
                    previewFile: { previewFile = $0 },
                    viewImage: { viewerItem = $0 },
                    showSheet: { presentedSheet = ConversationSheetContent(content: $0) },
                    open: { openedRoute = $0 }
                ))
                .environment(\.rowExpansion, RowExpansion(
                    isExpanded: { [model] in model.isExpanded(rowID: $0, partID: $1) },
                    setExpanded: { [model] in model.setExpanded($0, rowID: $1, partID: $2) }
                ))
                .environment(\.markdownBlocks, MarkdownBlockSource(blocks: { [model] in model.markdownBlocks(for: $0) }))
                .environment(\.hostTheme, hostTheme)
        )
    }

    #if os(iOS)
    /// 列的長按選單項目(#488):檔案卡片、圖片卡片、shell 區塊;項目與規則同舊列表,其他列沒有(留給文字選取)。
    /// 選單由列表(UIKit)呈現,開著時列表暫停捲動與套用內容。
    private func menuEntries(for rowContent: ChatListRowContent) -> [ChatListMenuEntry] {
        if case .pending(let pendingItem) = rowContent {
            return queuedPromptMenuEntries(for: pendingItem)
        }
        guard case .entry(let row, _) = rowContent, case .item(let item) = row.entry else { return [] }
        switch item {
        case .agentFile(let card) where card.file.isImageFromAgent:
            return ChatListMenuPlan.items(for: .image).map { menuEntry($0, card: card, display: AgentFileCardDisplay(file: card.file)) }
        case .agentFile(let card):
            let display = AgentFileCardDisplay(file: card.file)
            let shareableFile = AgentFileOpenDisplay(state: model.agentFiles?.opens[card.file.path]).shareableFile
            let kind = ChatListMenuKind.file(hasCopyableContent: display.copyableContent != nil, hasShareableFile: shareableFile != nil)
            return ChatListMenuPlan.items(for: kind).map { menuEntry($0, card: card, display: display, shareableFile: shareableFile) }
        case .shell(let run):
            let output = ShellRunDisplay(run: run).copyableOutput
            return ChatListMenuPlan.items(for: .shell(hasCopyableOutput: output != nil)).map { menuItem in
                switch menuItem {
                case .copyOutput: ChatListMenuEntry(item: menuItem) { if let output { Clipboard.copy(output) } }
                default: ChatListMenuEntry(item: menuItem) { Clipboard.copy(run.command) }
                }
            }
        default:
            return []
        }
    }
    #endif

    #if os(iOS)
    /// 離線佇列裡的訊息(#347):還沒送出的才能取消;出問題的訊息在列內有自己的按鈕。
    private func queuedPromptMenuEntries(for pendingItem: PendingItem) -> [ChatListMenuEntry] {
        guard let queued = model.queuedPrompts.first(where: { "queued-\($0.id.uuidString)" == pendingItem.id }) else { return [] }
        return ChatListMenuPlan.items(for: .queuedPrompt(canCancel: queued.problem == nil)).map { menuItem in
            ChatListMenuEntry(item: menuItem) { model.deleteQueued(queued.id) }
        }
    }

    private func menuEntry(_ menuItem: ChatListMenuItem, card: AgentFileCard, display: AgentFileCardDisplay, shareableFile: URL? = nil) -> ChatListMenuEntry {
        switch menuItem {
        case .details:
            ChatListMenuEntry(item: menuItem) { presentedSheet = ConversationSheetContent(content: AnyView(AgentFileDetailsSheet(card: card, display: display))) }
        case .copyContent:
            ChatListMenuEntry(item: menuItem) { if let content = display.copyableContent { Clipboard.copy(content) } }
        case .share:
            ChatListMenuEntry(item: menuItem, shareURL: shareableFile)
        default:
            ChatListMenuEntry(item: menuItem) { Clipboard.copy(card.file.path) }
        }
    }
    #endif

    @ViewBuilder
    private func rowBody(_ rowContent: ChatListRowContent) -> some View {
        switch rowContent {
        case .older(let older):
            olderRowView(older)
        case .away(let summary, _):
            AwayDividerView(summary: summary, isCollapsed: Binding(get: { model.isAwayCollapsed }, set: { model.isAwayCollapsed = $0 }))
        case .entry(let row, let turnHeader):
            switch row.entry {
            case .item(let item):
                ConversationItemView(item: item, turnHeader: turnHeader)
                    .environment(\.expansionRowID, row.id)
            case .echo(let echo):
                EchoBubbleView(echo: echo) {
                    Task { await model.retry(echoID: echo.id) }
                }
            }
        case .pending(let item):
            // 待送項目(#347):離線排隊、做完再送、撤回倒數統一從 `pendingItems` 讀，接在最後一則訊息後面。
            pendingRow(item)
        case .notice(let shown):
            ErrorLabel(shown.text, area: "ConversationView", error: shown.descriptor)
                .font(.footnote)
                .accessibilityIdentifier("conversation.sendWhenDone.notice")
        case .prompt:
            // 「需要你」的提示放在最後一則(提問)下方，內容層(F8、HIG 20.7)。
            BlockedPromptView(model: model)
        case .working:
            // 即時預覽在列表最底下(工作中狀態在輸入卡片上方的膠囊);agent 停止工作就消失(F5.11)。
            ConversationWorkingRow(model: model)
        }
    }

    @ViewBuilder
    private var chatList: some View {
        #if os(iOS)
        // 列表延伸到玻璃導覽列、橫幅與輸入列底下(DESIGN.md:內容從玻璃底下捲過去);避開玻璃後的安全區域框由探針量出,
        // 交給列表當上下 inset。覆蓋物(進度條、跳到最新)掛在這個避開玻璃的容器上,所以停在輸入列上方。
        ZStack {
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { safeAreaFrame = $0 }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ChatListView(
                content: listContent,
                rowEnvironment: ChatListRowEnvironment(
                    hostTheme: hostTheme, inlineSlashNames: model.inlineSlashNames),
                isSceneActive: scenePhase == .active,
                model: model, handle: listHandle, rowView: { rowView($0) }, menuEntries: { menuEntries(for: $0) },
                safeAreaFrame: safeAreaFrame,
                onShowsJumpToLatestChanged: { isAwayFromBottom = $0 },
                onVisibleHeightChanged: { conversationHeight.update(isEmptyState ? nil : $0) },
                hitchRecorder: hitchRecorder, tracksReadingDrift: tracksReadingDrift
            )
            .ignoresSafeArea(.container, edges: .vertical)
        }
        // 重新載入、換 session 讀取中:舊訊息留著，頂端只放一條不遮擋的細進度條(#329)。
        .overlay(alignment: .top) {
            if model.isRefreshing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("conversation.refreshing")
            }
        }
        .onChange(of: conversationHeight.arrangementRevision) { listHandle.inputBarArranged() }
        // 跳到最新(#476):顯示只看離底距離。跟隨中新內容撐長的瞬間也會量到很遠,
        // 延遲一下才顯示,避免閃現;閱讀中(往上捲)立刻顯示。位置在輸入列上方正中間(#476)。
        .task(id: isAwayFromBottom) {
            guard isAwayFromBottom else {
                jumpToLatestVisible = false
                return
            }
            if model.isFollowingLatest {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            jumpToLatestVisible = true
        }
        .overlay(alignment: .bottom) {
            if jumpToLatestVisible {
                Button {
                    listHandle.jumpToLatest()
                } label: {
                    Label("Jump to Latest", systemImage: "arrow.down")
                        .labelStyle(.iconOnly)
                }
                // 系統玻璃按鈕(spec #612、#627):「減少透明度」由系統處理,不自加尺寸與玻璃。
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .padding(.bottom, 8)
                .accessibilityIdentifier("conversation.jumpToLatest")
            }
        }
        #else
        Color.clear
        #endif
    }

    /// 頂端固定一列：載入中轉圈／「對話開頭」／空白(保持底部錨定穩定)。
    @ViewBuilder
    private func olderRowView(_ older: ConversationModel.Older) -> some View {
        switch older {
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
        case .scrollbackLimitReached:
            Text("Scroll down to the latest message to read earlier ones again.")
                .font(.footnote)
                .foregroundStyle(.secondaryText)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("conversation.scrollbackLimit")
        }
    }

    // MARK: - 佔位與標示

    /// 沒有快取、也還沒讀到任何訊息時的骨架(#356、#496):使用者泡泡、Agent 文字段、步驟列的佔位(設計稿 `Skeleton`,用 `SkeletonBlock` 拼出版型),不是整區轉圈。
    /// 對 VoiceOver 是一個「載入中」的元素;輸入列不受影響,可先打字。
    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 18) {
            SkeletonBlock(height: 44, cornerRadius: 20)
                .containerRelativeFrame(.horizontal) { width, _ in width * 0.62 }
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 9) {
                SkeletonBlock().containerRelativeFrame(.horizontal) { width, _ in width * 0.88 }
                SkeletonBlock().containerRelativeFrame(.horizontal) { width, _ in width * 0.82 }
                SkeletonBlock().containerRelativeFrame(.horizontal) { width, _ in width * 0.55 }
            }
            SkeletonBlock(height: 20).containerRelativeFrame(.horizontal) { width, _ in width * 0.34 }
            VStack(alignment: .leading, spacing: 9) {
                SkeletonBlock().containerRelativeFrame(.horizontal) { width, _ in width * 0.84 }
                SkeletonBlock().containerRelativeFrame(.horizontal) { width, _ in width * 0.68 }
            }
            SkeletonBlock(height: 44, cornerRadius: 20)
                .containerRelativeFrame(.horizontal) { width, _ in width * 0.44 }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .skeleton(identifier: "conversation.loading", label: "Loading conversation…")
    }

    @ViewBuilder
    private var placeholder: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 20) {
                // 沒命中快取時先留白約 300 毫秒,一般讀取在這段內完成,不會看到骨架換成列表。
                if model.showsLoadingSkeleton { loadingSkeleton }
                // 等超過約 1.5 秒才出現，用系統的 ProgressView(HIG〈Progress indicators〉);
                // 骨架已經在(它本身在脈動)就不再疊第二個載入指示。
                if model.showsLoadingIndicator, !model.showsLoadingSkeleton {
                    ProgressView().accessibilityIdentifier("conversation.loadingIndicator")
                }
            }
        case .waitingForSession:
            ContentUnavailableView {
                Label("Getting Ready", systemImage: "hourglass")
            } description: {
                if model.transcriptStartsAfterFirstMessage {
                    Text("Its messages appear here after you send the first message.")
                } else {
                    Text("Waiting for the agent to get ready. Its messages appear here soon.")
                }
            }
        case .missingSession:
            ContentUnavailableView {
                Label("Can’t Identify This Chat", systemImage: "questionmark.bubble")
            } description: {
                if let command = model.missingSessionCommand {
                    VStack(spacing: 12) {
                        Text("This chat can’t be read. On the host, paste the command below to start a new chat.")
                        Text(verbatim: command)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                            .accessibilityIdentifier("conversation.missingSession.command")
                        Button("Copy", systemImage: "document.on.document") { Clipboard.copy(command) }
                            .buttonStyle(.bordered)
                            .tint(.primary)
                            .controlSize(.small)
                            .accessibilityLabel(Text("Copy \(command)"))
                            .accessibilityIdentifier("conversation.missingSession.copy")
                    }
                } else {
                    Text("This chat can’t be shown yet. Update this agent’s herdr integration on the host, then open the chat again.")
                }
            }
        case .unsupported:
            ContentUnavailableView {
                Label("Chat History Isn’t Available", systemImage: "terminal")
            } description: {
                Text("This agent’s chat can’t be shown yet. Use the terminal to see it.")
            }
        case .agentGone:
            ContentUnavailableView {
                Label("Agent Ended", systemImage: "xmark.bubble")
            } description: {
                Text("This pane no longer has an agent running.")
            }
        case .newConversation:
            ContentUnavailableView {
                Label("New Conversation", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Its messages appear here after you send the first message.")
            }
            .accessibilityIdentifier("conversation.new")
        case .ready:
            ContentUnavailableView {
                Label("No Messages Yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(model.agentStatus == .working ? "The agent is working. Its reply will appear here." : "Messages in this chat appear here.")
            }
        }
    }

    /// 非干擾式標示：不在進入畫面時跳 alert,也不只用自動消失的 toast(HIG 20.5)。
}

extension ConversationStatusSummary.Banner {
    var text: Text {
        switch self {
        case .transcript(let banner): Text(banner.text)
        case .readOnly: Text("This device is paired read-only, so it can’t send anything to this host.")
        case .hostServiceUpdateRequired(let message): Text(verbatim: message)
        }
    }

    var symbol: String {
        switch self {
        case .transcript(let banner): banner.symbol
        case .readOnly: "lock"
        case .hostServiceUpdateRequired: "arrow.down.circle"
        }
    }
}

/// 標題列的重新載入(F5.7)。停止與強制結束在輸入卡片的停止列(#220,`StopBar`)。
extension ConversationModel.Banner {
    var text: LocalizedStringKey {
        switch self {
        case .offline: "Offline — showing the last loaded conversation."
        case .unreadable: "Couldn’t open this chat’s record on the host."
        case .readFailed: "Couldn’t update the conversation. Retrying…"
        case .ambiguous: "More than one saved chat matches this one, so none is shown."
        case .compressed: "Codex shortened this chat, so it can’t be shown here. Open the chat on the host to see it."
        case .tooLarge: "This chat is too long to show here. Open it on the host to see it."
        }
    }

    var symbol: String {
        switch self {
        case .offline: "wifi.slash"
        case .unreadable: "lock"
        case .readFailed: "arrow.clockwise"
        case .ambiguous: "questionmark.folder"
        case .compressed: "archivebox"
        case .tooLarge: "doc.text.magnifyingglass"
        }
    }
}

// MARK: - 項目

struct ConversationItemView: View {
    let item: ConversationItem
    /// 這則是每輪第一則 Agent 文字時帶頭像與名稱(#351)。
    var turnHeader: AgentTurnHeader?

    var body: some View {
        switch item {
        case .user(let bubble):
            UserBubbleView(bubble: bubble)
        case .agentText(let text):
            AgentMessageView(text: text, turnHeader: turnHeader)
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
    var turnHeader: AgentTurnHeader?
    @Environment(\.agentImages) private var context
    @Environment(\.markdownBlocks) private var markdownBlocks
    /// 點了的主機路徑：開啟中或開不了時在訊息下方顯示狀態。
    @State private var openedPath: String?
    @State private var previewFile: URL?
    @State private var viewer: ImageViewerItem?

    var body: some View {
        let markdown = MarkdownView(blocks: markdownBlocks?.blocks(text) ?? Markdown.parse(text.markdown))
        VStack(alignment: .leading, spacing: 6) {
            if let turnHeader {
                AgentTurnHeaderView(header: turnHeader, date: text.date)
            }
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
        // 列在 UICollectionView 的 cell 裡沒有可靠的呈現者:交給對話畫面(其他畫面照舊自己呈現)。
        .presentedQuickLook($previewFile)
        .presentedImageViewer(item: $viewer)
    }

    private func open(_ path: String) {
        openedPath = path
        guard let loads = context.loads else { return }
        let scope = context.scope()
        Task {
            if HostPathOpenStatus.isImage(path) {
                await loads.load(path, scope: scope, userRequested: true)
                guard case .loaded(let data, _) = loads.states[path] else { return }
                viewer = ImageViewerItem(data: data, name: HostPathOpenStatus.name(of: path))
            } else {
                guard let file = await loads.open(path, scope: scope) else { return }
                previewFile = file
            }
            if openedPath == path { openedPath = nil }
        }
    }
}

/// 每輪開頭的頭像與名稱(#351)。
struct AgentTurnHeader: Equatable {
    var kind: AgentKind
    var name: String
}

/// Agent 回覆不包泡泡，每輪開頭一列小頭像、名稱與時間(原型 A1 的 `.who`)。時間跟著 Dynamic Type 放大(#258)。
/// VoiceOver 念在訊息的標籤裡(「Agent:」),這一列隱藏、不重複。
struct AgentTurnHeaderView: View {
    let header: AgentTurnHeader
    let date: Date?

    var body: some View {
        HStack(spacing: 6) {
            AgentKindAvatar(kind: header.kind, compact: true)
            Text(verbatim: header.name)
                .fontWeight(.semibold)
            if let date {
                Text(date, format: .dateTime.hour().minute())
            }
        }
        .font(.caption)
        .foregroundStyle(.secondaryText)
        .accessibilityHidden(true)
        .accessibilityIdentifier("conversation.agent.header")
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
    @Environment(\.inlineSlashNames) private var slashNames

    /// 開頭的 skill／slash 指令用主色(有主機主題時是主題 accent;#329),其餘照泡泡的文字色。
    static func highlighted(_ text: String, known: Set<String> = []) -> AttributedString {
        var attributed = AttributedString(text)
        for range in SlashToken.ranges(in: text, known: known) {
            if let start = AttributedString.Index(range.lowerBound, within: attributed),
               let end = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[start..<end].foregroundColor = Color.commandText
            }
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
                    BubbleImagesView(
                        images: known + Array(repeating: nil, count: max(0, bubble.imageCount - known.count)),
                        hostPaths: bubble.imagePaths)
                }
                ForEach(bubble.filePaths, id: \.self) { UserFileCardView(path: $0) }
                if !bubble.displayText.isEmpty {
                    Text(Self.highlighted(bubble.displayText, known: slashNames))
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
        .accessibilityElement(children: bubble.imageCount > 0 || !bubble.filePaths.isEmpty ? .contain : .combine)
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

/// skill 載入與系統註記:預設收成一行(#349，同工具串),點一下展開全文;大字級不截斷。
struct CapsuleNote: View {
    let text: Text
    let symbol: String
    private let expansion = ExpansionState(partID: "note")
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(text: Text, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    init(text: String, symbol: String) {
        self.init(text: Text(verbatim: text), symbol: symbol)
    }

    var body: some View {
        let expanded = expansion.binding
        Button { expanded.wrappedValue.toggle() } label: {
            Label { text } icon: { Image(systemName: symbol) }
                .font(.footnote)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(expanded.wrappedValue || dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 工具串：預設收合成一行摘要;有失敗時摘要旁有紅點。展開後每個呼叫一列，有結果者可再展開看結果(最多 12 行)。
struct ToolRunView: View {
    let run: ToolRun
    private let expansion: ExpansionState

    /// 展開狀態跟著列(時間軸),列被重用也不會收起;沒有注入時(其他畫面)用本地狀態。
    private var expanded: Binding<Bool> { expansion.binding }

    init(run: ToolRun) {
        self.run = run
        expansion = ExpansionState(partID: nil, rowID: run.expansionID)
    }

    var body: some View {
        DisclosureGroup(isExpanded: expanded) {
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
    private let expansion: ExpansionState

    /// 展開狀態以列 id 加步驟 id 存時間軸(思考、呼叫結果),捲出畫面再回來仍展開。
    init(step: ToolStep) {
        self.step = step
        expansion = ExpansionState(partID: step.id)
    }

    var body: some View {
        let expanded = expansion.binding
        switch step.kind {
        case .thinking(let text):
            DisclosureGroup(isExpanded: expanded) {
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
                DisclosureGroup(isExpanded: expanded) {
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

/// 即時預覽列:`livePreview` 在自己的 body 裡讀,列嵌在 `UIHostingConfiguration` 時也跟著更新。
struct ConversationWorkingRow: View {
    let model: ConversationModel

    var body: some View {
        WorkingIndicatorView(preview: model.livePreview)
    }
}
