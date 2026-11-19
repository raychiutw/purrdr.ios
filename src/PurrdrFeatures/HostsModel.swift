import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH

public struct HostRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var subtitle: String
    public var session: String?
    public var isSelected: Bool
    /// 使用者替主機選的圖示;沒選過是預設圖示。
    public var icon: HostIcon
    /// HTTPS 主機在這支裝置還沒有裝置權杖(例如主機同步帶來的):要先連線配對。
    public var needsPairing: Bool
    /// HTTPS 主機的主機服務比這版 app 已知的最新版舊：可更新到的版本(#198)。
    public var hostServiceUpdate: String?

    public init(
        id: UUID, title: String, subtitle: String, session: String?, isSelected: Bool, icon: HostIcon = .default,
        needsPairing: Bool = false, hostServiceUpdate: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.session = session
        self.isSelected = isSelected
        self.icon = icon
        self.needsPairing = needsPairing
        self.hostServiceUpdate = hostServiceUpdate
    }
}

/// Demo 的示範主機(#34):Demo 主機出現在列表時一起出現，演出多主機合併列表(含一台連不上)。
///
/// 不是已存主機：不在主機清單、不能編輯或刪除、不同步;通道由 composition root 給(Demo 主機或一律連不上的通道),
/// 永遠不連網路。
public struct DemoCompanionHost: Sendable {
    public var id: UUID
    public var name: String
    public var icon: HostIcon
    public var channel: any HostChannel

    public init(id: UUID, name: String, icon: HostIcon, channel: any HostChannel) {
        self.id = id
        self.name = name
        self.icon = icon
        self.channel = channel
    }
}

/// 管理主機時的錯誤。
public enum HostManagementError: Error, Equatable {
    case emptyName
    case notFound
}

/// 主機清單與選取中主機(行為規格 F1.1、F1.3;#39)。
///
/// - 所有主機的 Agent 合併在同一個列表(`agentList`):每台主機各自一條主機通道、各自的 herdr client、
///   列表、列操作、草稿與推播開關(`HostMember`);一台連不上不影響其他台。
/// - 選取中主機只決定新聊天開在哪裡、列表排序與哪些列標示主機名、套用誰的主題(#23)、推播設定讀哪台、方案用量畫面預設查哪台;
///   切換不關閉、不重建任何連線。
/// - Demo 主機只在沒有已存主機、或使用者選了它時出現在列表。
/// - 選取存在本機(`HostSelectionStore`),重新啟動後選回同一台;存的主機已刪除時選第一台，沒有主機就選 Demo 主機。
/// - 編輯、刪除主機時關閉那台主機的連線;刪除也清掉它的對話快取、釘選／靜音、草稿與圖示。
@MainActor
@Observable
public final class HostsModel {
    public private(set) var selection: HostSelection = .demo
    public private(set) var hosts: [HostConfiguration] = [] {
        // 主機清單變了就重讀圖示(新增、同步來的主機可能已有存過的圖示)。
        didSet { icons = Dictionary(hosts.map { ($0.id, hostIcons.icon(for: $0.id) ?? .default) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// 所有主機合併的 Agent 列表。
    public let agentList: MergedAgentListModel
    /// 選取中主機的 Codex 啟動器(設定頁，行為規格 §4.2)。同意以主機為單位記住。
    public private(set) var codexLauncher: CodexLauncherModel
    /// 讀不到已存主機時的說明。
    public private(set) var loadError: String?
    /// Tailscale SSH check mode 的提示。所有主機通道共用;composition root 把它的 `observer` 交給主機通道。
    public let tailscaleCheck: TailscaleCheckModel
    /// 使用者新增、修改、刪除主機時通知(主機同步)。
    public weak var changeRecorder: (any HostChangeRecorder)?
    /// 對話作答的觸覺(composition root 注入系統觸覺;測試不播放)。
    public var haptics: any Haptics = SilentHaptics()
    /// 成功送出幾次 prompt 後請求評分(#34);`nil` 時不請求。所有主機、所有聊天共用一份計數。
    public var reviewPrompt: ReviewPrompt?

    private let store: any HostStore
    private let selectionStore: any HostSelectionStore
    /// 方案用量畫面上次選的主機與 Agent。
    private let planUsageSelection: any PlanUsageSelectionStore
    /// 登入 Shell、檔案上次選的電腦(#245)。
    private let hostPickerStore: any HostPickerStore
    private let demoChannel: any HostChannel
    /// Demo 主機的主機取檔(#225;composition root 給 Demo 的 adapter,Features 不 import Demo)。
    private let demoFiles: any HostFileFetching
    /// Demo 的示範主機(#34)。
    private let demoCompanions: [DemoCompanionHost]
    private let makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    private let credentials: HostCredentials
    /// HTTPS 主機的裝置權杖、連線配對與主機連線(ADR-0010)。
    private let hostService: HostServiceAccess
    private let conversationCache: any ConversationCache
    private let preferences: any HostChatPreferencesStore
    private let hostIcons: any HostIconStore
    /// 已存主機的圖示(從 `hostIcons` 讀出)。是 observable 狀態：改了圖示，依賴它的畫面(主機清單、主機鈕)重新計算。
    private var icons: [UUID: HostIcon] = [:]
    /// 已建立的主機通道(以主機 id)。
    private var channels: [UUID: any HostChannel] = [:]
    /// 這支裝置還沒有裝置權杖的 HTTPS 主機(主機清單標示要配對)。
    private var unpairedHostIDs: Set<UUID> = []
    /// 主機服務的更新提示(#198)。
    private let hostServiceUpdates: HostServiceUpdates
    /// HTTPS 主機回報的主機服務版本(`checkHostServiceVersions` 讀到的)。
    private var hostServiceVersions: [UUID: String] = [:]
    /// 使用者關閉了更新提示的版本(從 `hostServiceUpdates` 的存放處讀出，observable)。
    private var dismissedHostServiceUpdates: [UUID: String] = [:]
    /// 已建立的 HTTPS 主機連線(以主機 id)。
    private var hostServiceConnections: [UUID: any HostConnection] = [:]
    /// 列表上每台主機的連線與 model(以主機身分)。
    private var members: [HostSelection: HostMember] = [:]
    /// Demo 主機的主機寫入同意(Demo 不持久化，行為規格 F21)。
    private let demoConsent: any HostWriteConsentStore
    /// 真主機的主機寫入同意(以主機 id 為鍵);移除主機時清除。
    private let hostConsent: any HostWriteConsentStore
    /// 推播(後台、權限、配對紀錄);`nil` 時沒有推播。
    private let pushService: PushService?
    /// 送出圖片的手機副本(泡泡顯示用;所有主機共用，檔名不重複)。
    private let attachmentStore: any AttachmentStore
    private let diagnostics: DiagnosticLog

    /// - Parameters:
    ///   - conversationCache: 對話快取(所有主機共用一個存放處，key 依主機分開)。
    ///   - preferences: 釘選、靜音等本機偏好(依主機分開：同一個 session 值在不同主機是不同的聊天)。
    ///   - hostIcons: 使用者替主機選的圖示。
    ///   - selectionStore: 選取中主機的存放處。
    ///   - swipeHint: 列表滑動提示是否已經不用再顯示(使用者用過滑動面板的動作)。
    ///   - listMode: 列表檢視(Spaces／Agents)的存放處。
    ///   - credentials: OpenSSH 主機的祕密與這支裝置的金鑰。
    ///   - demoCompanions: Demo 的示範主機(#34);Demo 主機出現在列表時一起出現。
    ///   - diagnostics: 不給使用者看的紀錄(例如偵測到的作業系統存不進這支裝置)。
    ///   - makeChannel: 依端點、host key pin 與憑證來源建立主機通道(憑證在撥號時才讀)。
    public init(
        store: any HostStore, demoChannel: any HostChannel, demoFiles: any HostFileFetching = UnsupportedHostFileFetcher(),
        demoCompanions: [DemoCompanionHost] = [],
        conversationCache: any ConversationCache = InMemoryConversationCache(),
        preferences: any HostChatPreferencesStore = InMemoryHostChatPreferencesStore(),
        hostIcons: any HostIconStore = InMemoryHostIconStore(),
        selectionStore: any HostSelectionStore = InMemoryHostSelectionStore(),
        planUsageSelection: any PlanUsageSelectionStore = InMemoryPlanUsageSelectionStore(),
        hostPicker hostPickerStore: any HostPickerStore = InMemoryHostPickerStore(),
        demoConsent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(),
        hostConsent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(), credentials: HostCredentials = HostCredentials(),
        hostService: HostServiceAccess = HostServiceAccess(),
        hostServiceUpdates: HostServiceUpdates = HostServiceUpdates(store: InMemoryHostServiceUpdateStore()),
        push pushService: PushService? = nil, tailscaleCheck: TailscaleCheckModel? = nil,
        attachmentStore: any AttachmentStore = FileAttachmentStore.app(),
        swipeHint: any SwipeHintStore = InMemorySwipeHintStore(),
        listMode: any AgentListModeStore = InMemoryAgentListModeStore(),
        diagnostics: DiagnosticLog = .system(category: "hosts"),
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.store = store
        agentList = MergedAgentListModel(swipeHint: swipeHint, modeStore: listMode)
        self.selectionStore = selectionStore
        self.planUsageSelection = planUsageSelection
        self.hostPickerStore = hostPickerStore
        self.demoChannel = demoChannel
        self.demoFiles = demoFiles
        self.demoCompanions = demoCompanions
        self.makeChannel = makeChannel
        self.credentials = credentials
        self.hostService = hostService
        self.hostServiceUpdates = hostServiceUpdates
        dismissedHostServiceUpdates = hostServiceUpdates.store.dismissedVersions()
        self.conversationCache = conversationCache
        self.preferences = preferences
        self.hostIcons = hostIcons
        self.demoConsent = demoConsent
        self.hostConsent = hostConsent
        self.pushService = pushService
        self.tailscaleCheck = tailscaleCheck ?? TailscaleCheckModel()
        self.attachmentStore = attachmentStore
        self.diagnostics = diagnostics
        codexLauncher = CodexLauncherModel(host: CodexLauncherHost(channel: demoChannel), hostID: Self.demoID, consent: demoConsent)
        rebuildMembers()
    }

    /// Demo 主機在同意紀錄裡的主機 id。
    static let demoID = "demo"

    /// 選取中主機的 herdr client(設定頁讀 herdr 版本用)。
    public var herdrClient: HerdrClient { member(for: selection).client }
    /// 選取中主機的推播開關(#29)。
    public var push: PushModel { member(for: selection).push }
    /// 選取中主機的主機主題(#23;DESIGN.md:選取中主機決定套用誰的主題)。每台主機各自一份、同意以主機為單位記住;
    /// 換選取中主機就換成那台的(讀過的主題留著，切回來不必等下一次輪詢)。
    public var hostTheme: HostThemeModel { member(for: selection).hostTheme }
    /// 選取中主機的「You should know」註記(設定頁撤掉修改用，#23)。每台主機各自一份，寫回的同意以主機為單位記住。
    public var youShouldKnow: YouShouldKnowModel { member(for: selection).youShouldKnow }

    /// 方案用量畫面的 model(#177):打開畫面時建立。主機選單是 Demo 主機加上所有已存主機，預設選取中主機。
    public func planUsage() -> PlanUsageModel {
        let options = [PlanUsageHostOption(id: .demo, name: name(of: .demo))]
            + hosts.map { PlanUsageHostOption(id: .host($0.id), name: $0.name, icon: icon(for: $0.id)) }
        return PlanUsageModel(hosts: options, fallback: selection, store: planUsageSelection) { [weak self] host, agent in
            self?.planUsageSource(host, agent)
        }
    }

    /// 方案用量的來源：Demo 主機是本機假資料(不耗 token 與傳輸);SSH 主機經主機通道;HTTPS 主機不支援。
    private func planUsageSource(_ host: HostSelection, _ agent: PlanUsageAgent) -> PlanUsageSource? {
        let channel: any HostChannel
        let cost: PlanUsageQueryCost
        let hostID: String
        var files: HostFiles?
        switch host {
        case .demo:
            (channel, cost, hostID) = (demoChannel, .free, Self.demoID)
        case .host(let id):
            guard let configuration = hosts.first(where: { $0.id == id }), !configuration.connectionMethod.usesHostService else {
                return nil
            }
            let member = member(for: host)
            (channel, cost, hostID, files) = (member.channel, .transfer, id.uuidString, member.hostFiles)
        }
        switch agent {
        case .claudeCode:
            return .claude(channel: channel, files: files, cost: cost, hostID: hostID, consent: host == .demo ? demoConsent : hostConsent)
        case .codex:
            return .codex(channel: channel, cost: cost)
        }
    }

    /// 某台主機上某個 Pane 的終端機 model(標題)。
    public func terminal(_ route: ChatRoute, title: String) -> PaneTerminalModel {
        PaneTerminalModel(client: member(for: route.host).terminals, paneID: route.paneID, title: title)
    }

    /// 選取中主機有沒有登入 Shell 與檔案(HTTPS 連線方式沒有，ADR-0010)。
    public var selectedHostSupportsShell: Bool { selectedHost?.supportsLoginShell ?? true }

    /// 登入 Shell、檔案的主機挑選鈕(#245):只列支援的主機(HTTPS 主機沒有，ADR-0010),預設上次選的電腦或選取中主機。
    public func hostPicker(for scope: HostPickerScope) -> HostPickerModel {
        let options = hostPickerOptions { $0.supportsLoginShell }
        return .remembering(scope, options: options, fallback: selection, store: hostPickerStore)
    }

    /// 新增聊天的主機挑選鈕(#245):所有主機;預設聊天列表篩選的主機(`nil` 是所有主機，用選取中主機)。
    public func newChatHostPicker(listFilter: HostSelection?) -> HostPickerModel {
        .newChat(options: hostPickerOptions { _ in true }, listFilter: listFilter, selection: selection)
    }

    /// 新增聊天的主機挑選鈕，預設聊天列表目前篩選的主機(#244)。
    public func newChatHostPicker() -> HostPickerModel {
        newChatHostPicker(listFilter: agentList.hostFilter)
    }

    /// Demo 主機加上符合條件的已存主機(同方案用量的主機選單)。
    private func hostPickerOptions(_ isIncluded: (HostConfiguration) -> Bool) -> [HostPickerOption] {
        [HostPickerOption(id: .demo, name: name(of: .demo))]
            + hosts.filter(isIncluded).map { HostPickerOption(id: .host($0.id), name: $0.name, icon: icon(for: $0.id)) }
    }

    /// 某台主機的登入 Shell(標題是主機名稱;Demo 主機是回顯的 shell)。
    public func loginShell(on host: HostSelection) -> LoginShellModel {
        LoginShellModel(channel: member(for: host).channel, title: name(of: host))
    }

    /// 某台主機的檔案瀏覽(從家目錄開始);壓得小的檔案以 gzip 傳輸，主機沒有 `gzip` 時記在那台主機的成員上。
    public func folderBrowser(on host: HostSelection) -> FolderBrowserModel {
        let member = member(for: host)
        let folders = HostFolders(channel: member.channel, deflate: SystemDeflate(), gzipAvailability: member.gzipAvailability)
        return FolderBrowserModel(folders: folders, hostName: name(of: host))
    }

    /// 某台主機上某個 Agent 的對話 model(列表看到的 session)。非選取中主機的聊天在標題列帶主機名(#44)。
    public func conversation(_ route: ChatRoute, sessionID: String?) -> ConversationModel {
        let member = member(for: route.host)
        let model = ConversationModel(
            client: member.client, transcripts: member.transcripts, paneID: route.paneID, knownSessionID: sessionID,
            cache: conversationCache(for: route.host), drafts: member.drafts, slashDiscovery: ClaudeSlashDiscovery(channel: member.channel),
            haptics: haptics,
            hostName: { [weak self] in
                guard let self, route.host != self.selection else { return nil }
                return self.name(of: route.host)
            },
            // Windows 主機也能上傳(#68:`ImageUploader` 經 `WindowsHostChannel` 送 PowerShell 版)。
            images: ComposerImages(uploader: ImageUploader(channel: member.channel), store: attachmentStore),
            updates: member.list.updates)
        // 註記屬於聊天所在的主機(#23):寫回也寫到那台。
        model.youShouldKnow = member.youShouldKnow
        // 圖片縮圖讀聊天所在的主機(#225)。
        model.agentFiles = member.agentFiles
        model.onPromptDelivered = { [weak self] in self?.reviewPrompt?.promptDelivered() }
        return model
    }

    /// 某台主機上的新增對話(#18;主機由新增聊天的主機挑選鈕決定，#245)。
    public func newChat(on host: HostSelection) -> NewChatModel {
        let member = member(for: host)
        let folders = NewChatFolders(channel: member.channel)
        return NewChatModel(launcher: NewChatLauncher(client: member.client, folders: folders), folders: folders)
    }

    /// 新對話開始後：重讀列表，開那台主機上新 workspace 的 root pane 的聊天(行為規格 F3.2 第 5 步)。
    public func openStartedChat(_ workspace: CreatedWorkspace, on host: HostSelection) async {
        let list = agentList
        await list.load()
        list.openedChat = ChatRoute(host: host, paneID: workspace.rootPaneID)
    }

    /// 某台主機的對話快取(key 加上主機身分)。
    public func conversationCache(for selection: HostSelection) -> any ConversationCache {
        HostScopedConversationCache(base: conversationCache, scope: selection.storedValue)
    }

    public var rows: [HostRow] {
        hosts.map { host in
            let subtitle = host.ssh.map { "\($0.endpoint.username)@\($0.endpoint.host):\($0.endpoint.port)" }
                ?? host.hostService?.description ?? ""
            return HostRow(
                id: host.id, title: host.name, subtitle: subtitle, session: host.ssh?.herdr.session,
                isSelected: selection == .host(host.id), icon: icon(for: host.id), needsPairing: unpairedHostIDs.contains(host.id),
                hostServiceUpdate: hostServiceUpdate(for: host.id))
        }
    }

    /// 讀每台已配對 HTTPS 主機的主機服務版本(主機清單出現時;已連線的主機不多花一個請求)。連不上的略過。
    public func checkHostServiceVersions() async {
        let targets = hosts.compactMap { host -> (UUID, any HostConnection)? in
            guard case .https(let address) = host.connection, !unpairedHostIDs.contains(host.id) else { return nil }
            return (host.id, hostServiceConnection(for: host, address: address))
        }
        for (id, connection) in targets {
            if let version = try? await connection.hostServiceVersion() { hostServiceVersions[id] = version }
        }
    }

    /// 不再提示這台主機更新到目前提示的版本(app 知道更新的版本時再提示)。
    public func dismissHostServiceUpdate(for id: UUID) {
        guard let offered = hostServiceUpdate(for: id) else { return }
        dismissedHostServiceUpdates[id] = offered
        hostServiceUpdates.store.setDismissedVersion(offered, for: id)
    }

    private func hostServiceUpdate(for id: UUID) -> String? {
        guard let installed = hostServiceVersions[id], let offered = hostServiceUpdates.offeredVersion(installed: installed),
            dismissedHostServiceUpdates[id] != offered
        else { return nil }
        return offered
    }

    /// 列表上的主機 id:已存主機，加上 Demo 出現時的示範主機(#34)。新視窗以它判斷主機還在不在。
    public var listedHostIDs: [UUID] {
        hosts.map(\.id) + (members[.demo] == nil ? [] : demoCompanions.map(\.id))
    }

    /// 選取中的主機(Demo 時為 `nil`)。
    public var selectedHost: HostConfiguration? {
        guard case .host(let id) = selection else { return nil }
        return hosts.first { $0.id == id }
    }

    /// 主機的顯示名稱(Demo 主機是「Demo」)。
    public func name(of host: HostSelection) -> String {
        switch host {
        case .demo: String(localized: "Demo")
        case .host(let id): hosts.first { $0.id == id }?.name ?? companion(id)?.name ?? ""
        }
    }

    /// 主機的圖示;沒選過是預設圖示。
    public func icon(for id: UUID) -> HostIcon {
        icons[id] ?? .default
    }

    /// 選取中主機的圖示(主機鈕用)。
    public var selectionIcon: HostIcon { icon(of: selection) }

    /// 替主機選圖示：列表與主機鈕立刻改用它;改了已存主機的圖示時記成修改(主機同步上傳，#243)。
    public func setIcon(_ icon: HostIcon, for id: UUID) {
        let changed = icons[id] != icon && hosts.contains { $0.id == id }
        hostIcons.setIcon(icon, for: id)
        icons[id] = icon
        if changed { changeRecorder?.hostSaved(id) }
        rebuildMembers()
    }

    /// 從儲存讀主機清單，選回上次選取的主機。
    public func load() {
        do {
            hosts = try sortedHosts()
            refreshPairing()
            loadError = nil
        } catch {
            loadError = String(localized: "Couldn’t read saved hosts on this device. \(error.localizedDescription)")
        }
        select(validSelection(selectionStore.load()))
    }

    /// 選取主機並存起來。只改新聊天開在哪裡、列表排序與主機名標示、推播設定讀哪台;
    /// 不關閉、不重建任何連線(#39)。
    public func select(_ selection: HostSelection) {
        let host: HostConfiguration?
        switch selection {
        case .demo: host = nil
        case .host(let id):
            guard let found = hosts.first(where: { $0.id == id }) else { return }
            host = found
        }
        self.selection = selection
        selectionStore.save(selection)
        rebuildMembers()
        codexLauncher = CodexLauncherModel(
            host: CodexLauncherHost(channel: member(for: selection).channel), hostID: host?.id.uuidString ?? Self.demoID,
            consent: host == nil ? demoConsent : hostConsent)
    }

    /// 新增或編輯主機並儲存後：重讀清單並選取它。設定改了，那台主機的連線一律關閉重建。
    public func didSave(_ host: HostConfiguration) {
        changeRecorder?.hostSaved(host.id)
        hosts = (try? sortedHosts()) ?? hosts
        refreshPairing()
        dropChannel(of: host.id)
        members[.host(host.id)] = nil
        select(.host(host.id))
    }

    /// 重新命名：只改名稱，連線與選取不變。
    public func rename(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HostManagementError.emptyName }
        guard var host = hosts.first(where: { $0.id == id }) else { throw HostManagementError.notFound }
        host.name = name
        try store.save(host)
        changeRecorder?.hostSaved(id)
        hosts = (try? sortedHosts()) ?? hosts
        rebuildMembers()
    }

    /// 刪除主機(主機清單先跟使用者確認，#235):先刪這台主機的祕密(刪不掉就整個停下，避免留下孤兒祕密，行為規格 §8.1),
    /// 再刪掉此裝置上的設定與 host key pin、清除這台主機的所有主機寫入同意(行為規格 F18)、關閉連線，
    /// 清掉對話快取、釘選／靜音、草稿與圖示。推播配對則不等待地從主機上刪掉並撤銷(行為規格 F14)。
    /// 刪的是選取中主機時，改選第一台剩下的主機(沒有就選 Demo 主機)並存起來。
    public func delete(_ id: UUID) async throws {
        try await remove(id)
        changeRecorder?.hostDeleted(id)
    }

    /// 套用主機同步的結果(別台裝置的新增、修改、刪除)。不通知 `changeRecorder`(不是這支裝置的修改)。
    /// 連線相關的欄位(位址、連線方式、host key 指紋)改了就關掉那台的連線;選取中主機被刪掉時改選第一台。
    public func applySynced(_ outcome: HostSyncOutcome) async throws {
        var reselect = false
        for host in outcome.saves {
            let previous = hosts.first { $0.id == host.id }
            try store.save(host)
            if let previous, previous.connection != host.connection {
                dropChannel(of: host.id)
                members[.host(host.id)] = nil
                reselect = reselect || selection == .host(host.id)
            }
        }
        // 不認得的值(較新版 app 加的圖示)沿用這支裝置的;要在重讀清單前存好，清單重讀時會一起讀圖示。
        for (id, stored) in outcome.icons {
            if let icon = HostIcon(stored: stored) { hostIcons.setIcon(icon, for: id) }
        }
        hosts = (try? sortedHosts()) ?? hosts
        for id in outcome.deletions {
            try await remove(id)
        }
        refreshPairing()
        if reselect { select(validSelection(selection)) } else { rebuildMembers() }
    }

    private func remove(_ id: UUID) async throws {
        let removed = hosts.first { $0.id == id }
        // 刪配對要再連一次主機：祕密刪掉前先讀出來，給刪配對用的連線。
        let secret = try? credentials.secrets.secret(for: id)
        let deviceToken = try? hostService.tokens.deviceToken(for: id)
        try credentials.secrets.setSecret(nil, for: id)
        try hostService.tokens.setDeviceToken(nil, for: id)
        try store.delete(id)
        if let removed, let settings = removed.ssh {
            forgetPush(of: removed, settings: settings, secret: secret)
        } else if let address = removed?.hostService, let deviceToken {
            // 主機離線時權杖留在主機上，可在主機上撤銷。
            hostService.revokeWithoutWaiting(deviceToken, at: address)
        }
        hostConsent.revokeAll(host: id.uuidString)
        hosts.removeAll { $0.id == id }
        let channel = channels.removeValue(forKey: id)
        let connection = hostServiceConnections.removeValue(forKey: id)
        members[.host(id)] = nil
        preferences.removeAll(for: .host(id))
        hostIcons.setIcon(nil, for: id)
        try? FileManager.default.removeItem(at: AgentFileLoads.defaultDownloadDirectory.appending(path: id.uuidString, directoryHint: .isDirectory))
        hostServiceVersions[id] = nil
        dismissedHostServiceUpdates[id] = nil
        hostServiceUpdates.store.setDismissedVersion(nil, for: id)
        if selection == .host(id) { select(validSelection(nil)) } else { rebuildMembers() }
        await conversationCache.removeAll(chatKeyPrefix: HostScopedConversationCache.prefix(scope: HostSelection.host(id).storedValue))
        await channel?.disconnect()
        await connection?.disconnect()
    }

    /// 主機的分享連結(QR code 內容)。不含任何祕密。
    public func shareLink(for id: UUID) -> URL? {
        hosts.first { $0.id == id }.map(HostShareLink.url(for:))
    }

    /// 點了推播通知：開配對主機上該 Agent 的聊天。所有主機都在同一個列表，所以不改選取中主機。
    /// 不認得的配對(主機已移除)不動。
    public func open(_ route: PushRoute, pairings: any PushPairingStore) {
        guard let hostID = pairings.host(forKeyHash: route.keyHash), let id = UUID(uuidString: hostID),
              hosts.contains(where: { $0.id == id }) else { return }
        if let paneID = route.paneID { agentList.openedChat = ChatRoute(host: .host(id), paneID: paneID) }
    }

    /// 啟動時：APNs token 換了就向後台重新註冊推播配對。
    public func refreshPushRegistrations() async {
        await pushService?.refreshRegistrations()
    }

    /// 點了推播通知(用 app 的推播紀錄)。
    public func open(_ route: PushRoute) {
        guard let pushService else { return }
        open(route, pairings: pushService.store)
    }

    /// 新增主機(`editing` 為 `nil`)或編輯既有主機的畫面 model。
    public func makeEditor(editing: HostConfiguration? = nil) -> HostEditorModel {
        HostEditorModel(
            store: store, editing: editing, credentials: credentials, hostService: hostService,
            icon: editing.map { icon(for: $0.id) } ?? .default, saveIcon: setIcon(_:for:), makeChannel: makeChannel)
    }

    /// 從主機分享連結或主機配對指令的 QR code(`purrdr://pair?…`)新增主機：帶入欄位的編輯器。
    /// 連結不合法時丟 `HostShareLinkError` 或 `HostServicePairingLinkError`。
    public func makeImportEditor(_ url: URL) throws -> HostEditorModel {
        if HostServicePairingLink.isPairingLink(url) {
            return HostEditorModel(
                store: store, pairing: try HostServicePairingLink(url: url), credentials: credentials, hostService: hostService,
                saveIcon: setIcon(_:for:), makeChannel: makeChannel)
        }
        return HostEditorModel(
            store: store, importing: try HostShareLink.decode(url), credentials: credentials, hostService: hostService,
            saveIcon: setIcon(_:for:), makeChannel: makeChannel)
    }

    // MARK: - 連線韌性(行為規格 §7.4、§7.5)

    /// 網路路徑改變(狀態 + 可用介面類型組成的字串):丟棄所有主機的連線，下一個指令在新路由上撥號;
    /// 每台主機的列表立刻重連。第一次回報只記錄。被丟棄連線上的 Pane 終端機以「連線中斷」結束(不自動重連)。
    /// - Returns: 丟棄連線並重連的 task(沒有要重設時是 `nil`);呼叫端不必等它，測試用來對齊。
    @discardableResult
    public func networkPathChanged(_ signature: String) -> Task<Void, Never>? {
        defer { networkPath = signature }
        guard let previous = networkPath, previous != signature else { return nil }
        let dropped = Array(channels.values) + [demoChannel]
        let droppedConnections = Array(hostServiceConnections.values)
        // 診斷(#133):實機斷線時分辨是不是網路切換丟掉了連線。
        diagnostics.error("Network path changed (\(previous) → \(signature)): dropping \(channels.count) host connection(s)")
        let agentList = agentList
        return Task {
            for channel in dropped { await channel.disconnect() }
            for connection in droppedConnections { await connection.disconnect() }
            agentList.retryNow()
        }
    }

    public func sceneDidEnterBackground(at date: Date) {
        backgroundSince = date
    }

    /// 回到前景：背景超過 60 秒就對已建立的連線跑喚醒探測，死掉的連線在 3 秒內被丟棄;有丟棄就讓每台主機的列表立刻重連。
    public func sceneDidBecomeActive(at date: Date) async {
        guard let since = backgroundSince else { return }
        backgroundSince = nil
        guard date.timeIntervalSince(since) > Double(WakeProbe.backgroundThreshold.components.seconds) else { return }
        let probed = channels
        let dead = await withTaskGroup(of: (UUID, Bool).self) { group in
            for (id, channel) in probed { group.addTask { (id, await WakeProbe(channel: channel).run()) } }
            var dead: [UUID] = []
            for await (id, alive) in group where !alive { dead.append(id) }
            return dead
        }
        guard !dead.isEmpty else { return }
        // 診斷(#133):喚醒探測失敗會丟棄那台主機的連線。
        let backgroundSeconds = Int(date.timeIntervalSince(since))
        for id in dead { diagnostics.error("Wake probe failed after \(backgroundSeconds)s in background: dropped the connection to host \(id)") }
        agentList.retryNow()
    }

    private var networkPath: String?
    private var backgroundSince: Date?

    // MARK: - 內部

    /// 重算哪些 HTTPS 主機在這支裝置沒有裝置權杖(讀 Keychain,所以不在每次畫列表時做)。
    private func refreshPairing() {
        let tokens = hostService.tokens
        unpairedHostIDs = Set(hosts.filter { host in
            host.connectionMethod.usesHostService && (try? tokens.deviceToken(for: host.id)) == nil
        }.map(\.id))
    }

    private func sortedHosts() throws -> [HostConfiguration] {
        try store.loadHosts().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func validSelection(_ stored: HostSelection?) -> HostSelection {
        switch stored {
        case .demo?: return .demo
        case .host(let id)? where hosts.contains(where: { $0.id == id }): return .host(id)
        default: return hosts.first.map { .host($0.id) } ?? .demo
        }
    }

    private func icon(of host: HostSelection) -> HostIcon {
        guard case .host(let id) = host else { return .default }
        return companion(id)?.icon ?? icon(for: id)
    }

    private func companion(_ id: UUID) -> DemoCompanionHost? {
        demoCompanions.first { $0.id == id }
    }

    /// 列表上的主機：所有已存主機(依名稱);Demo 主機與它的示範主機(#34)只在沒有已存主機或選了 Demo 時。
    /// 已有的成員沿用(連線、列、草稿不重建)。
    private func rebuildMembers() {
        var wanted: [HostSelection] = hosts.map { .host($0.id) }
        if hosts.isEmpty || selection == .demo { wanted.insert(contentsOf: [.demo] + demoCompanions.map { .host($0.id) }, at: 0) }
        members = members.filter { wanted.contains($0.key) }
        for host in wanted where members[host] == nil { members[host] = makeMember(host) }
        let sources = wanted.compactMap { host in
            members[host].map { member in
                MergedAgentListModel.Source(
                    host: host, name: name(of: host), icon: icon(of: host), list: member.list, actions: member.actions,
                    notes: member.youShouldKnow)
            }
        }
        agentList.update(sources: sources, selected: selection)
    }

    /// 某台主機的成員;不在列表上時(例如剛刪除的主機還開著的畫面)暫時建一個不保留的。
    private func member(for host: HostSelection) -> HostMember {
        members[host] ?? makeMember(host)
    }

    private func makeMember(_ host: HostSelection) -> HostMember {
        if case .host(let id) = host, let companion = companion(id) {
            return HostMember(
                host: host, configuration: nil, channel: companion.channel, preferences: preferences.store(for: host),
                push: pushService, consent: demoConsent)
        }
        let configuration: HostConfiguration? = switch host {
        case .demo: nil
        case .host(let id): hosts.first { $0.id == id }
        }
        guard let configuration else {
            return HostMember(
                host: host, configuration: nil, channel: demoChannel, files: demoFiles, preferences: preferences.store(for: host),
                push: pushService, consent: demoConsent)
        }
        switch configuration.connection {
        case .https(let address):
            let connection = hostServiceConnection(for: configuration, address: address)
            return HostMember(
                host: host, configuration: configuration, channel: UnsupportedHostChannel(), connection: connection,
                // 主機取檔走同一條主機服務連線(#227);UI 測試的替身連線沒有取檔。
                files: (connection as? any HostFileFetching) ?? UnsupportedHostFileFetcher(), preferences: preferences.store(for: host),
                push: nil, consent: hostConsent)
        case .tailscaleSSH(let settings), .openSSH(let settings, _):
            return HostMember(
                host: host, configuration: configuration, channel: channel(for: configuration, settings: settings),
                preferences: preferences.store(for: host), push: pushService, consent: hostConsent)
        }
    }

    private func hostServiceConnection(for host: HostConfiguration, address: HostServiceAddress) -> any HostConnection {
        if let connection = hostServiceConnections[host.id] { return connection }
        let connection = hostService.connection(for: host, address: address)
        hostServiceConnections[host.id] = connection
        return connection
    }

    private func channel(for host: HostConfiguration, settings: HostConfiguration.SSHSettings) -> any HostChannel {
        if let channel = channels[host.id] { return channel }
        // Windows 主機的指令換成 PowerShell 方言(#26);其他原樣。作業系統未知(主機同步帶來的新主機)時先偵測，
        // 不對可能是 Windows 的主機送 POSIX 指令。
        let base = makeChannel(settings.endpoint, settings.hostKeyPin, credentials.provider(for: host))
        let id = host.id
        let channel = host.operatingSystem?.channel(base) ?? OperatingSystemDetectingChannel(base) { [weak self] operatingSystem in
            await self?.recordOperatingSystem(operatingSystem, for: id)
        }
        channels[host.id] = channel
        return channel
    }

    /// 存下偵測到的作業系統。不是使用者的修改，不通知主機同步(作業系統也不同步);連線不重建。
    /// 存不進去時只留診斷紀錄：這次執行仍用偵測結果，下次啟動再偵測一次，不必打斷使用者。
    private func recordOperatingSystem(_ operatingSystem: HostOperatingSystem, for id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }), hosts[index].operatingSystem == nil else { return }
        hosts[index].operatingSystem = operatingSystem
        do {
            try store.save(hosts[index])
        } catch {
            diagnostics.error("Couldn’t save the detected operating system (\(operatingSystem.rawValue)) for host \(id): \(error)")
        }
    }

    /// 推播配對：另開一條不放進 `channels` 的連線刪掉主機上的配對(刪除主機會關閉它原本的連線)。
    private func forgetPush(of host: HostConfiguration, settings: HostConfiguration.SSHSettings, secret: HostSecret?) {
        guard let pushService else { return }
        let provider = credentials.provider(
            method: host.connectionMethod, authentication: host.authentication, hostID: nil, entered: secret)
        pushService.forget(
            hostID: host.id.uuidString, channel: makeChannel(settings.endpoint, settings.hostKeyPin, provider), herdr: settings.herdr)
    }

    private func dropChannel(of id: UUID) {
        let channel = channels.removeValue(forKey: id)
        let connection = hostServiceConnections.removeValue(forKey: id)
        guard channel != nil || connection != nil else { return }
        Task {
            await channel?.disconnect()
            await connection?.disconnect()
        }
    }
}

/// 列表上一台主機的連線與 model:各自的通道、herdr client、列表、列操作、草稿、推播開關、「You should know」註記與主機主題。
@MainActor
final class HostMember {
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

    /// - Parameters:
    ///   - connection: 上層功能用的主機連線;`nil` 時是包住 `channel` 的 SSH 連線。
    ///   - files: 主機取檔;`nil` 時經 `channel` 跑 SSH 的取檔腳本(主機跑不了時是 unsupported)。
    init(
        host: HostSelection, configuration: HostConfiguration?, channel: any HostChannel, connection: (any HostConnection)? = nil,
        files: (any HostFileFetching)? = nil, preferences: any ChatPreferencesStore, push pushService: PushService?,
        consent: any HostWriteConsentStore
    ) {
        self.host = host
        self.channel = channel
        let herdr = configuration?.ssh?.herdr ?? HerdrInstallation()
        let connection = connection ?? SSHHostConnection(
            channel: channel, herdr: herdr, followDiagnostics: DiagnosticLog.systemNotice(category: "transcript-follow"))
        client = HerdrClient(connection: connection)
        transcripts = TranscriptReader(connection: connection)
        terminals = PaneTerminalClient(connection: connection)
        let list = AgentListModel(client: client, transcripts: transcripts, host: host)
        self.list = list
        actions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await list.load() })
        let push = PushModel(service: pushService, hostID: configuration?.id.uuidString, channel: channel, herdr: herdr) {
            preferences.load().muted
        }
        self.push = push
        actions.mutedChanged = { muted in Task { await push.syncMuted(muted) } }
        let hostID = configuration?.id.uuidString ?? HostsModel.demoID
        let hostFiles = HostFiles.longRunning(channel: channel, diagnostics: DiagnosticLog.systemNotice(category: "host-files"))
        self.hostFiles = hostFiles
        // 點開的檔案依主機分資料夾，刪除主機時一起清(#228)。
        agentFiles = AgentFileLoads(
            fetcher: files ?? SSHHostFileFetcher(channel: channel, diagnostics: DiagnosticLog.systemNotice(category: "host-file-fetch")),
            downloadDirectory: AgentFileLoads.defaultDownloadDirectory.appending(path: hostID, directoryHint: .isDirectory))
        youShouldKnow = YouShouldKnowModel(host: YouShouldKnowHost(channel: channel, files: hostFiles), hostID: hostID, consent: consent)
        hostTheme = HostThemeModel(host: HostThemeHost(channel: channel, files: hostFiles), hostID: hostID, consent: consent)
    }
}
