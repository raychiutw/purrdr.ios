import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 聊天狀態摘要與待送項目(#347,spec #336):頂列、工作中膠囊、狀態 sheet、目前橫幅都從同一份摘要讀;
/// 撤回倒數、離線佇列、做完再送統一成待送項目。每種資訊只出現在摘要的一處。
@MainActor
@Suite("聊天狀態摘要")
struct ConversationStatusSummaryTests {
    static let since = Date(timeIntervalSince1970: 1_794_614_400)

    static func summary(
        agentStatus: AgentStatus? = .idle, isOffline: Bool = false, banner: ConversationModel.Banner? = nil, isReadOnly: Bool = false,
        hostServiceUpdateMessage: String? = nil, stopNeedsReconnect: Bool = false, workingSince: Date? = nil,
        stopPhase: StopPhase? = nil, isWritingLive: Bool = false, progress: AgentProgress = AgentProgress(), agentsPane: AgentsPane? = nil
    ) -> ConversationStatusSummary {
        ConversationStatusSummary(
            header: ConversationHeader(agent: nil, title: "ledger", status: agentStatus, isOffline: isOffline, hostName: "studio", progress: progress),
            banner: banner, isOffline: isOffline, isReadOnly: isReadOnly,
            hostServiceUpdateMessage: hostServiceUpdateMessage, stopNeedsReconnect: stopNeedsReconnect, workingSince: workingSince,
            stopPhase: stopPhase, isWritingLive: isWritingLive, progress: progress,
            agentsPane: agentsPane)
    }

    static func row(_ id: Int, _ state: DelegationStatus) -> AgentsPane.Row {
        AgentsPane.Row(id: id, state: state, kind: "general-purpose", task: "任務 \(id)", elapsedSeconds: 10, tokens: nil)
    }

    @Test("閒置：沒有膠囊、沒有橫幅，頂列說在線")
    func idleHasNoCapsuleOrBanner() {
        let summary = Self.summary()

        #expect(summary.header.status == .online)
        #expect(summary.working == nil)
        #expect(summary.banner == nil)
    }

    @Test("工作中：膠囊帶開始時間與背景子 Agent 數;頂列狀態是工作中")
    func workingShowsCapsuleWithBackgroundCount() {
        let pane = AgentsPane(rows: [Self.row(1, .running), Self.row(2, .running), Self.row(3, .completed)])
        let summary = Self.summary(agentStatus: .working, workingSince: Self.since, agentsPane: pane)

        #expect(summary.header.status == .working)
        #expect(summary.working?.since == Self.since)
        #expect(summary.working?.stopPhase == nil)
        #expect(summary.working?.runningBackgroundAgents == 2)
        #expect(summary.sheet.backgroundAgents == pane)
    }

    @Test("有即時預覽時膠囊標示正在寫")
    func writingLive() {
        let summary = Self.summary(agentStatus: .working, isWritingLive: true)

        #expect(summary.working?.isWriting == true)
    }

    @Test("停止進度或結果還在時膠囊仍在，即使狀態已不是工作中")
    func stopResultKeepsCapsule() {
        let summary = Self.summary(agentStatus: .idle, stopPhase: .stopped)

        #expect(summary.working?.stopPhase == .stopped)
    }

    @Test("需要你：沒有工作中膠囊(膠囊與問題卡片不並存)")
    func needsYouHasNoCapsule() {
        let summary = Self.summary(agentStatus: .blocked)

        #expect(summary.header.status == .needsYou)
        #expect(summary.working == nil)
    }

    @Test("唯讀裝置與離線都沒有膠囊(停止不可用)")
    func readOnlyAndOfflineHaveNoCapsule() {
        #expect(Self.summary(agentStatus: .working, isReadOnly: true).working == nil)
        #expect(Self.summary(agentStatus: .working, isOffline: true, banner: .offline).working == nil)
    }

    @Test("狀態 sheet：context 與待辦在 sheet 內容，頂列另有一行進度")
    func sheetCarriesProgress() {
        var progress = AgentProgress()
        progress.contextPercent = 62
        let summary = Self.summary(progress: progress)

        #expect(summary.sheet.progress.contextPercent == 62)
        #expect(summary.header.progressText == "62%")
    }

    @Test("離線：橫幅是離線，頂列離線;斷線前在工作時帶「重連後才能停止」")
    func offlineBanner() {
        let summary = Self.summary(isOffline: true, banner: .offline, stopNeedsReconnect: true)

        #expect(summary.header.status == .offline)
        #expect(summary.banner == .offline(needsReconnectToStop: true))
    }

    @Test("對話紀錄讀取問題用同一條橫幅")
    func transcriptBanner() {
        #expect(Self.summary(banner: .readFailed).banner == .transcript(.readFailed))
        #expect(Self.summary(banner: .compressed).banner == .transcript(.compressed))
    }

    @Test("唯讀裝置：橫幅是唯讀")
    func readOnlyBanner() {
        #expect(Self.summary(isReadOnly: true).banner == .readOnly)
    }

    @Test("主機服務版本不足：橫幅帶說明")
    func hostServiceUpdateBanner() {
        let summary = Self.summary(hostServiceUpdateMessage: "請更新主機服務")

        #expect(summary.banner == .hostServiceUpdateRequired("請更新主機服務"))
    }

    @Test("同時有多種提醒時只留一條：離線 > 對話紀錄 > 唯讀 > 主機服務版本")
    func onlyOneBannerByPriority() {
        let all = Self.summary(isOffline: true, banner: .offline, isReadOnly: true, hostServiceUpdateMessage: "請更新主機服務")
        #expect(all.banner == .offline(needsReconnectToStop: false))

        let readOnlyAndOld = Self.summary(isReadOnly: true, hostServiceUpdateMessage: "請更新主機服務")
        #expect(readOnlyAndOld.banner == .readOnly)

        let transcriptAndReadOnly = Self.summary(banner: .unreadable, isReadOnly: true)
        #expect(transcriptAndReadOnly.banner == .transcript(.unreadable))
    }

    // MARK: 待送項目

    @Test("待送項目：撤回倒數、離線排隊、做完再送統一成一份清單，順序是排隊、做完再送、倒數")
    func pendingItemsUnify() {
        let queued = QueuedPrompt(text: "排隊的", paneID: "w1:p6", workspaceID: "w1", sessionID: "s-1", createdAt: Self.since)
        let failed = QueuedPrompt(text: "沒送出的", paneID: "w1:p6", workspaceID: "w1", sessionID: "s-1", createdAt: Self.since, problem: .expired)
        let done = [SendWhenDoneItem(id: "a", text: "先做完", expectedSession: "s-1"), SendWhenDoneItem(id: "b", text: "再做", expectedSession: "s-1")]
        let undo = UndoSendCountdown.Pending(text: "倒數的", remainingSeconds: 3)

        let items = PendingItem.items(queued: [queued, failed], sendWhenDone: done, undo: undo)

        #expect(items.map(\.text) == ["排隊的", "沒送出的", "先做完", "再做", "倒數的"])
        #expect(items.map(\.kind) == [
            .offlineQueued, .offlineProblem(.expired), .sendWhenDone(position: 1), .sendWhenDone(position: 2),
            .undoCountdown(remainingSeconds: 3),
        ])
        #expect(Set(items.map(\.id)).count == 5)
    }

    @Test("沒有任何待送：清單是空的")
    func noPendingItems() {
        #expect(PendingItem.items(queued: [], sendWhenDone: [], undo: nil).isEmpty)
    }

    // MARK: 經 model

    @Test("model 的摘要：唯讀裝置握手後橫幅是唯讀，沒有膠囊")
    func modelSummaryForReadOnlyDevice() async throws {
        let setup = try ConversationReadOnlyTests.setup()
        await setup.host.bridge.expect(ConversationReadOnlyTests.bridge, reply: ConversationReadOnlyTests.snapshot(status: "working"))
        await setup.model.poll()

        let summary = setup.model.statusSummary
        #expect(summary.banner == .readOnly)
        #expect(summary.working == nil)
    }

    @Test("model 的待送項目：一開始是空的")
    func modelHasNoPendingItemsInitially() throws {
        let setup = try ConversationReadOnlyTests.setup()

        #expect(setup.model.pendingItems.isEmpty)
    }
}
