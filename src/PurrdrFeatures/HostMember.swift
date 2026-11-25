import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 成員建立畫面 model 時要向主機清單問的事(#564):名稱、啟用的 Agent、對話快取、離線佇列等都是清單或全 app 共用的狀態,
/// 以閉包交給成員,成員不持有 `HostsModel`。
@MainActor
struct HostMemberEnvironment {
    /// 主機的顯示名稱(Demo 主機是「Demo」)。
    var hostName: @MainActor (HostSelection) -> String = { _ in "" }
    /// 這台主機啟用的 Agent(#477)。
    var enabledAgents: @MainActor (HostSelection) -> Set<AgentID> = { _ in Set(HostAgentSettings.configurable) }
    /// 這個 id 還是不是已存主機(`hostSettings`、`agentSettings` 只給已存主機)。
    var isSavedHost: @MainActor (UUID) -> Bool = { _ in false }
    /// 所有主機共用的對話快取存放處(成員加上主機身分才存取)。
    var conversationCache: any ConversationCache = InMemoryConversationCache()
    var haptics: @MainActor () -> any Haptics = { SilentHaptics() }
    var attachmentStore: any AttachmentStore = FileAttachmentStore.app()
    var trafficMeter: @MainActor () -> TrafficMeter? = { nil }
    var undoSendSeconds: @MainActor () -> Int = { 0 }
    var publicModelCatalog: (any PublicModelCatalogFetching)?
    var reviewPrompt: @MainActor () -> ReviewPrompt? = { nil }
    var awayStart: @MainActor (ChatRoute) -> Date? = { _ in nil }
    var offlineQueue: @MainActor (HostSelection) -> OfflineQueue
    /// 這台主機能不能在既有 Workspace 新增聊天。
    var supportsNewChatInWorkspace: @MainActor (HostSelection) -> Bool = { _ in true }
    var skeletonRowCounts: any SkeletonRowCountStore = InMemorySkeletonRowCountStore()
    var usageDisplay = UsageDisplaySetting()
    /// 方案用量的來源(依主機連線方式選,連線方式的分派在 adapter,不在成員)。
    var planUsageSource: @MainActor (HostSelection, PlanUsageAgent) -> PlanUsageSource? = { _, _ in nil }
    /// 主機上有哪些 Agent(SSH 看設定資料夾、HTTPS 看快照;連不上丟錯誤)。
    var detectAgents: @MainActor (UUID) async throws -> Set<AgentID> = { _ in [] }
    var setEnabledAgents: @MainActor (Set<AgentID>, UUID) -> Void = { _, _ in }
    var hostConsent: any HostWriteConsentStore = InMemoryHostWriteConsentStore()
    var agentHostServices = AgentHostServices()

    /// 沒有接上主機清單的成員(測試只看能力組時用):畫面 model 工廠回傳的內容沒有意義。
    static var inert: HostMemberEnvironment {
        HostMemberEnvironment(offlineQueue: { OfflineQueue(host: $0.storedValue, store: InMemoryOfflineQueueStore()) { _, _ in .notSent(.rejected("")) } })
    }
}

/// 列表上一台主機的連線與 model:各自的通道、herdr client、列表、列操作、草稿、推播開關、「You should know」註記與主機主題。
/// 這台主機的畫面 model 由成員自己建(`HostMember+Screens.swift`)。
@MainActor
package final class HostMember {
    let host: HostSelection
    /// 只有 SSH 才有的功能(登入 Shell、推播外掛、主題、資料夾…)用;上層功能的 client 經主機連線建立。
    let channel: any HostChannel
    let client: HerdrClient
    let transcripts: TranscriptReader
    let terminals: PaneTerminalClient
    let list: AgentListModel
    let actions: WorkspaceActionsModel
    /// 輸入列草稿：離開聊天保留、重開 app 不保留(行為規格 F6.2)。每台主機一份(pane id 在每台主機都會重複)。
    let drafts = DraftStore()
    /// 這台主機的推播開關;這台主機的靜音改變時改寫它上面的靜音清單。
    let push: PushModel
    /// 這台主機的「You should know」註記(#23)。
    let youShouldKnow: YouShouldKnowModel
    /// 這台主機的主機主題(#23);選取中主機的才套用到畫面。
    let hostTheme: HostThemeModel
    /// 這台主機有沒有 `gzip`(檔案上傳的 gzip 傳輸，#76)。
    let gzipAvailability = HostGzipAvailability()
    /// 主題、註記、Claude 方案用量定期讀取共用的長駐通道(#203)。
    let hostFiles: HostFiles
    /// 聊天裡圖片卡片的縮圖(#225)與點開的檔案(#228),這台主機的聊天共用一份快取。
    let agentFiles: AgentFileLoads
    /// 聊天附加的圖片與檔案上傳到主機(#286)。
    let uploader: any HostUploading
    /// 變更頁的唯讀 git 讀取(#310)。
    let gitChanges: any GitChangesReading
    /// 各 session 的 Claude status line 狀態(#388):SSH 讀主機上的 session 檔,HTTPS 走主機服務的 `usage.session_context`。
    let sessionStatus: any ClaudeSessionStatusReading
    /// 各 session 的 Antigravity statusline 狀態(#448):只有 SSH 主機(包裝經 SSH 寫入),HTTPS 主機是 `nil`。
    let antigravityStatus: (any ClaudeSessionStatusReading)?
    /// 主機上的 Send When Done 佇列(#305);只有 HTTPS 主機(主機服務)有，其他是 `nil`。
    let sendWhenDoneHost: (any SendWhenDoneHosting)?
    /// 這台主機的能力組(adapter 交出,含每項沒有的原因)。
    let capabilities: HostCapabilities
    let environment: HostMemberEnvironment
    /// 主機頁的 Codex 啟動器(#274):每台主機一份,成員重建(主機設定改了、刪除)時一起丟掉。
    var codexLauncher: CodexLauncherModel?

    /// 成員只依能力組建立畫面 model(#563):不看連線方式。
    init(
        host: HostSelection, hostID: String, capabilities: HostCapabilities, preferences: any ChatPreferencesStore, push pushService: PushService?,
        environment: HostMemberEnvironment = .inert
    ) {
        self.host = host
        self.environment = environment
        let channel = capabilities.channel
        self.channel = channel
        self.capabilities = capabilities
        uploader = capabilities.uploads
        gitChanges = capabilities.git
        sendWhenDoneHost = capabilities.sendWhenDone.value
        let connection = capabilities.connection
        client = HerdrClient(connection: connection)
        transcripts = TranscriptReader(connection: connection)
        terminals = PaneTerminalClient(connection: connection)
        let list = AgentListModel(client: client, transcripts: transcripts, host: host)
        self.list = list
        actions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await list.load() })
        let installer = pushService.flatMap { service in capabilities.pushInstaller.value.map { $0(service) } }
        let push = PushModel(service: pushService, hostID: hostID == HostsModel.demoID ? nil : hostID, installer: installer) {
            preferences.load().muted
        }
        self.push = push
        // 連上這台主機(建立成員)時,推播開著就檢查外掛版本(#432;有頻率上限，失敗不打擾)。
        if push.state == .on { Task { await push.updatePluginIfNeeded() } }
        // 測試通知(#328):adapter 決定這台主機有沒有、怎麼送。
        if let pushService, let makeSender = capabilities.pushTestSender.value { push.testSender = makeSender(pushService) }
        actions.mutedChanged = { muted in Task { await push.syncMuted(muted) } }
        let hostFiles = capabilities.hostFiles
        self.hostFiles = hostFiles
        sessionStatus = capabilities.sessionStatus
        antigravityStatus = capabilities.antigravityStatus.value
        // 點開的檔案依主機分資料夾，刪除主機時一起清(#228)。
        agentFiles = AgentFileLoads(
            fetcher: capabilities.files,
            downloadDirectory: AgentFileLoads.defaultDownloadDirectory.appending(path: hostID, directoryHint: .isDirectory))
        youShouldKnow = YouShouldKnowModel(
            host: YouShouldKnowHost(channel: channel, files: hostFiles), hostID: hostID, consent: capabilities.consent)
        hostTheme = HostThemeModel(host: HostThemeHost(channel: channel, files: hostFiles), hostID: hostID, consent: capabilities.consent)
    }
}
