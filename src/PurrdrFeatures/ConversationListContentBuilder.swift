import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 對話列表內容的計算(#584):只讀列表自己需要的狀態(列、待送項目、離開摘要、工作中指示…),
/// 不讀頂列標題、橫幅、進度這類狀態摘要。畫面的 body 因此不會在那些狀態變化時重建整份列表內容。
@MainActor
enum ConversationListContentBuilder {
    /// 沒有任何可顯示的內容:列表照常存在(常駐),說明文字畫在列表上面(#487)。
    /// 認不出 session(#400)時,工作中指示不蓋掉說明:沒有對話可顯示,使用者需要知道原因與解法。
    static func isEmptyState(_ model: ConversationModel) -> Bool {
        model.phase == .missingSession
            || model.entries.isEmpty && model.pendingItems.isEmpty && model.prompt == nil && model.lastAnswer == nil && model.panel == nil
            && !model.showsWorkingIndicator
    }

    private static func rendersPendingRow(_ item: PendingItem, model: ConversationModel) -> Bool {
        switch item.kind {
        case .offlineQueued, .offlineProblem: model.queuedPrompts.contains { "queued-\($0.id.uuidString)" == item.id }
        case .sendWhenDone(let position): position == 1 && model.sendWhenDone != nil
        case .undoCountdown: model.undoSend?.pending != nil
        }
    }

    /// 每輪開頭的頭像與名稱(#351)。
    private static func agentTurnHeader(_ model: ConversationModel) -> AgentTurnHeader {
        AgentTurnHeader(kind: AgentKind(rawKind: model.agentKind ?? ""), name: model.agentName)
    }

    /// 列表由上而下的列與各列內容。列 id 取自對話時間軸(`model.rows`):回音被確認後 id 不變。
    static func make(_ model: ConversationModel) -> ChatListContent {
        let isEmptyState = Self.isEmptyState(model)
        var rows = model.rows
        var awayAnchorRowID: String?
        if let summary = model.awaySummary {
            if model.isAwayCollapsed {
                let hiddenEntryIDs = summary.hiddenIDs(in: rows.map { $0.entry.id })
                rows = rows.filter { !hiddenEntryIDs.contains($0.entry.id) }
            }
            awayAnchorRowID = rows.first { $0.entry.id == summary.anchorID }?.id
        }
        let turnStartIDs = ConversationEntry.turnStartTextIDs(in: rows.map(\.entry))
        let turnHeader = agentTurnHeader(model)
        let pendingItems = model.pendingItems.filter { rendersPendingRow($0, model: model) }
        let noticeText = model.sendWhenDone?.notice
        let showsPrompt = model.lastAnswer != nil
        let showsWorking = model.showsWorkingIndicator && model.workingSince != nil
        let showsOlder = !isEmptyState

        var rowContents: [String: ChatListRowContent] = [:]
        if showsOlder { rowContents[ChatListRowPlan.olderID] = .older(model.older) }
        for row in rows {
            rowContents[row.id] = .entry(row, turnHeader: turnStartIDs.contains(row.entry.id) ? turnHeader : nil)
        }
        if awayAnchorRowID != nil, let summary = model.awaySummary {
            rowContents[ChatListRowPlan.awayID] = .away(summary, isCollapsed: model.isAwayCollapsed)
        }
        for item in pendingItems { rowContents[item.id] = .pending(item) }
        if let noticeText { rowContents[ChatListRowPlan.noticeID] = .notice(noticeText) }
        if showsPrompt { rowContents[ChatListRowPlan.promptID] = .prompt }
        if showsWorking { rowContents[ChatListRowPlan.workingID] = .working }

        let ids = ChatListRowPlan.ids(
            includesOlder: showsOlder, rowIDs: rows.map(\.id), awayAnchorID: awayAnchorRowID, pendingIDs: pendingItems.map(\.id),
            noticeID: noticeText == nil ? nil : ChatListRowPlan.noticeID, showsPrompt: showsPrompt, showsWorking: showsWorking)
        return ChatListContent(ids: ids, rows: rowContents)
    }
}

/// 導覽列標題:自己讀狀態摘要,標題變化只重畫這個修飾,不波及列表。
struct ConversationNavigationTitle: ViewModifier {
    let model: ConversationModel
    @Environment(\.paneWindowTitle) private var paneWindowTitle

    func body(content: Content) -> some View {
        content.navigationTitle(paneWindowTitle ?? ConversationTitleContainer.displayTitle(model))
    }
}

/// 工具列中央的標題膠囊(#270)。
struct ConversationTitleContainer: View {
    let model: ConversationModel

    static func displayTitle(_ model: ConversationModel) -> String {
        model.statusSummary.header.title.isEmpty ? String(localized: "Chat") : model.statusSummary.header.title
    }

    var body: some View {
        ConversationTitleView(title: Self.displayTitle(model), header: model.statusSummary.header)
    }
}

/// VoiceOver 公告:讀 items 與狀態的變化,自己持有節流狀態,不放在對話畫面的 body 裡。
struct ConversationAnnouncement: ViewModifier {
    let model: ConversationModel
    @State private var announcer = ConversationAnnouncer()

    func body(content: Content) -> some View {
        content
            .onChange(of: ConversationAnnouncer.Input(items: model.items, status: model.agentStatus, title: ConversationTitleContainer.displayTitle(model)), initial: true) { _, input in
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

    private func announce(_ text: String?) {
        guard let text else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}

/// 頂列下方唯一的一條浮動橫幅(#348):對話紀錄問題、唯讀與主機服務版本都在這裡,輸入列與卡片不再重複。
struct ConversationBannerView: View {
    let model: ConversationModel

    var body: some View {
        if let kind = model.statusSummary.banner {
            HStack {
                Label {
                    kind.text
                } icon: {
                    Image(systemName: kind.symbol)
                }
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .floatingGlass(in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("conversation.banner")
        }
    }
}
