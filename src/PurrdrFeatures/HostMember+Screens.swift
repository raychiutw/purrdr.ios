import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 一台主機的畫面 model 工廠(#564):畫面 model 作用在哪台主機,就向那台主機的成員要。
/// 清單或全 app 共用的狀態經 `environment` 取得。
extension HostMember {
    /// 這台主機的對話快取(key 加上主機身分)。
    var conversationCache: any ConversationCache {
        HostScopedConversationCache(base: environment.conversationCache, scope: host.storedValue)
    }

    /// 這個 Pane 的終端機 model(標題)。
    package func terminal(paneID: String, title: String) -> PaneTerminalModel {
        PaneTerminalModel(client: terminals, paneID: paneID, title: title)
    }

    /// 這台主機的登入 Shell(標題是主機名稱;Demo 主機是回顯的 shell)。
    package func loginShell() -> LoginShellModel {
        LoginShellModel(channel: channel, title: environment.hostName(host))
    }

    /// 這台主機的檔案瀏覽(從家目錄開始);壓得小的檔案以 gzip 傳輸，主機沒有 `gzip` 時記在這個成員上。
    package func folderBrowser() -> FolderBrowserModel {
        let folders = HostFolders(channel: channel, deflate: SystemDeflate(), gzipAvailability: gzipAvailability)
        return FolderBrowserModel(folders: folders, hostName: environment.hostName(host), skeletonRowCounts: environment.skeletonRowCounts)
    }

    /// 把文字放進這台主機某個聊天的輸入框(草稿):新增聊天沒送出的第一則訊息(#272)。
    package func keepDraft(_ text: String, paneID: String) {
        drafts.save(text, chatKey: paneID, session: nil)
    }

    /// 這台主機上某個 Agent 的對話 model(列表看到的 session)。非選取中主機的聊天在標題列帶主機名(#44)。
    package func conversation(_ route: ChatRoute, sessionID: String?) -> ConversationModel {
        let environment = environment
        let host = host
        let model = ConversationModel(
            client: client, transcripts: transcripts, paneID: route.paneID, knownSessionID: sessionID,
            // 列表已有這個 pane 的對話目標:找對話檔與讀主機狀態並行(#661)。
            knownTarget: sessionID == nil ? nil : list.updates.snapshot?.agents.first { $0.paneID == route.paneID }?.transcriptTarget,
            cache: conversationCache, drafts: drafts,
            slashDiscovery: capabilities.slashDiscovery.value,
            haptics: environment.haptics(),
            // 標題列副標一律是聊天所在主機的名稱(#270)。
            hostName: { environment.hostName(host) },
            images: ComposerAttachments.Dependencies(
                uploader: uploader, store: environment.attachmentStore, videoCompressor: AVVideoCompressor(),
                isOnCellular: { [meter = environment.trafficMeter()] in meter?.currentNetwork == .cellular }),
            updates: list.updates,
            // 送出管線(#299):機密偵測在最前面(#302,只在本機判斷),再來是撤回倒數(#300),
            // 倒數結束時離線就排進這台主機的離線佇列(#301)。
            // 「做完再送」開著時排進主機的佇列(#305),不經撤回倒數與離線佇列。
            sendStages: SendStages(
                secretCheck: SecretCheck(),
                sendWhenDone: SendWhenDoneStep(model: SendWhenDoneModel(host: sendWhenDoneHost, paneID: route.paneID)),
                undo: UndoSendCountdown(seconds: { environment.undoSendSeconds() }),
                offlineQueue: OfflineQueueStep(queue: environment.offlineQueue(host))),
            // 註記屬於聊天所在的主機(#23)、圖片縮圖讀這台(#225)、變更頁讀這台的 git(#310)、
            // context 取自這台 status line 檔(#388;Antigravity 的包裝只有 SSH 主機,#448)、
            // 對話紀錄認不得的行記到診斷紀錄(#449)、離開期間摘要用上次離開的時間(#308)。
            links: ConversationModel.HostLinks(
                youShouldKnow: offersMachineSettings ? youShouldKnow : nil, agentFiles: agentFiles, gitChanges: gitChanges,
                sessionStatusReader: sessionStatus,
                agentSessionStatusReaders: antigravityStatus.map { [.agy: $0] } ?? [:],
                onTranscriptSkips: TranscriptSkipLog.shared.report,
                onPromptDelivered: { environment.reviewPrompt()?.promptDelivered() },
                awayStart: { environment.awayStart(route) },
                operationTimings: environment.operationTimings()),
            // 模型目錄(#385):主機快取 → 公開目錄 → 內建對照表。
            modelCatalog: ModelCatalogResolver(host: SSHModelCatalogReader(channel: channel), publicCatalog: environment.publicModelCatalog))
        return model
    }

    /// 這台主機上的新增對話(#18;主機由新增聊天的主機挑選鈕決定，#245)。
    package func newChat(preselectingWorkspace workspaceID: String? = nil) -> NewChatModel {
        let folders = capabilities.folders
        let model = NewChatModel(
            launcher: NewChatLauncher(client: client, folders: folders, timings: environment.operationTimings()), folders: folders,
            agents: HostAgentSettings.newChatAgents(enabled: environment.enabledAgents(host)),
            // HTTPS 主機服務要 0.15.0 起才有 tab.create。
            supportsExistingWorkspaces: environment.supportsNewChatInWorkspace(host))
        if let workspaceID { model.preselectWorkspace(workspaceID) }
        return model
    }

    /// 用量區(#389):面板(單一 Agent)與主機 tab(Claude 與 Codex)共用。HTTPS 主機沒有來源,整區是「等主機服務支援」。
    /// `detectsInstallation`:主機 tab 只列主機上偵測到的 Agent(Antigravity,#465);面板的 Agent 是聊天正在跑的,不偵測。
    package func usageSection(agents: [AgentID], detectsInstallation: Bool = false) -> UsageSectionModel {
        // 只查、只列這台主機啟用的 Agent(#477)。
        let enabled = environment.enabledAgents(host)
        let shown = agents.filter { HostAgentSettings.showsUsage(of: $0, enabled: enabled) }
        let environment = environment
        let host = host
        return UsageSectionModel(
            hostName: environment.hostName(host), agents: shown, display: environment.usageDisplay, detectsInstallation: detectsInstallation
        ) { agent in
            environment.planUsageSource(host, agent)
        }
    }

    /// 這台主機的主機設定(#274):主機頁(主機清單的 ⓘ)下方的主機主題、You should know、Codex 啟動器。
    /// 不是已存主機時是 `nil`;這台主機沒有的項目(HTTPS 沒有通道,#730)在 `HostSettings` 裡是 `nil`,畫面不顯示。
    package func settings() -> HostSettings? {
        guard case .host(let id) = host, environment.isSavedHost(id) else { return nil }
        guard offersMachineSettings else { return HostSettings(hostTheme: nil, youShouldKnow: nil, codexLauncher: nil) }
        // 畫面每次重繪都會呼叫：已有就不再寫回，否則改了被觀察的狀態會無限重繪。
        if let codexLauncher {
            return HostSettings(hostTheme: hostTheme, youShouldKnow: youShouldKnow, codexLauncher: codexLauncher)
        }
        guard let launcher = environment.agentHostServices.launcher(for: .codex, channel: channel, hostID: id.uuidString, consent: environment.hostConsent) else {
            return HostSettings(hostTheme: hostTheme, youShouldKnow: youShouldKnow, codexLauncher: nil)
        }
        codexLauncher = launcher
        return HostSettings(hostTheme: hostTheme, youShouldKnow: youShouldKnow, codexLauncher: launcher)
    }

    /// 主機頁「Agent」子頁的 model;不是已存主機(範例主機)時是 `nil`。
    package func agentSettings() -> HostAgentSettingsModel? {
        guard case .host(let id) = host, environment.isSavedHost(id) else { return nil }
        let environment = environment
        return HostAgentSettingsModel(
            enabled: environment.enabledAgents(host),
            detect: { try await environment.detectAgents(id) },
            save: { environment.setEnabledAgents($0, id) })
    }
}
