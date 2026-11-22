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
    /// HTTPS 主機目前的主機服務版本(讀到之前、SSH 主機是 `nil`,#362)。
    public var hostServiceVersion: String?
    /// HTTPS 主機的主機服務比最新 Release 舊：可更新到的版本(#198)。
    public var hostServiceUpdate: String?
    /// 有可更新版本時，依這台主機已安裝的版本要執行的更新指令。
    public var hostServiceUpdateCommands: HostServiceUpdateCommands?

    public init(
        id: UUID, title: String, subtitle: String, session: String?, isSelected: Bool, icon: HostIcon = .default,
        needsPairing: Bool = false, hostServiceVersion: String? = nil, hostServiceUpdate: String? = nil,
        hostServiceUpdateCommands: HostServiceUpdateCommands? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.session = session
        self.isSelected = isSelected
        self.icon = icon
        self.needsPairing = needsPairing
        self.hostServiceVersion = hostServiceVersion
        self.hostServiceUpdate = hostServiceUpdate
        self.hostServiceUpdateCommands = hostServiceUpdateCommands
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
        didSet {
            icons = Dictionary(hosts.map { ($0.id, hostIcons.icon(for: $0.id) ?? .default) }, uniquingKeysWith: { first, _ in first })
            // 通知的副標題要顯示主機名稱(#431):名稱對應表由推播服務寫到 App Group。
            pushService?.updateHostNames(Dictionary(hosts.map { ($0.id.uuidString, $0.name) }, uniquingKeysWith: { first, _ in first }))
        }
    }
    /// 所有主機合併的 Agent 列表。
    public let agentList: MergedAgentListModel
    /// 讀不到已存主機時的說明。
    public private(set) var loadError: String?
    /// Tailscale SSH check mode 的提示。所有主機通道共用;composition root 把它的 `observer` 交給主機通道。
    public let tailscaleCheck: TailscaleCheckModel
    /// 使用者新增、修改、刪除主機時通知(主機同步)。
    public weak var changeRecorder: (any HostChangeRecorder)?
    /// 對話作答的觸覺(composition root 注入系統觸覺;測試不播放)。
    public var haptics: any Haptics = SilentHaptics()
    /// 數據用量的流量計量(#353):建立主機連線時接上(之後建的連線才算;app 啟動時就設好)。
    public var trafficMeter: TrafficMeter?
    /// 成功送出幾次 prompt 後請求評分(#34);`nil` 時不請求。所有主機、所有聊天共用一份計數。
    public var reviewPrompt: ReviewPrompt?
    /// 送出可撤回的秒數(#300),每次送出時讀;預設讀本機偏好(設定頁改的那一個)。
    @ObservationIgnored public var undoSendSeconds: @MainActor () -> Int = { UndoSendSettings.seconds(in: .standard) }

    private let store: any HostStore
    /// 離線佇列存放處(#301);每台主機一份佇列，同一台的聊天共用。
    private let offlineQueueStore: any OfflineQueueStore
    private var offlineQueues: [HostSelection: OfflineQueue] = [:]
    private let selectionStore: any HostSelectionStore
    private let currentHostStore: any CurrentHostStore
    /// 方案用量畫面上次選的主機與 Agent。
    private let planUsageSelection: any PlanUsageSelectionStore
    /// 用量的「已用／剩餘」全域設定(#389):用量區、方案用量頁、context 與設定共用同一份。
    public let usageDisplay: UsageDisplaySetting
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
    /// 以唯讀權杖配對的 HTTPS 主機(`refreshOverviewFacts` 讀到的,#392)。
    private var readOnlyHostIDs: Set<UUID> = []
    /// 主機服務的更新提示(#198)。
    private let hostServiceUpdates: HostServiceUpdates
    /// HTTPS 主機回報的主機服務版本(`checkHostServiceVersions` 讀到的)。
    /// 模型目錄的第二層(公開目錄);`nil`(UI 測試)不連網路。
    private let publicModelCatalog: (any PublicModelCatalogFetching)?
    private var hostServiceVersions: [UUID: String] = [:]
    /// 最新的主機服務版本(`checkHostServiceVersions` 從 `hostServiceUpdates.releases` 取得;取不到是 `nil`,#362)。
    private var latestHostServiceVersion: String?
    /// 使用者關閉了更新提示的版本(從 `hostServiceUpdates` 的存放處讀出，observable)。
    private var dismissedHostServiceUpdates: [UUID: String] = [:]
    /// 已建立的 HTTPS 主機連線(以主機 id)。
    private var hostServiceConnections: [UUID: any HostConnection] = [:]
    /// 列表上每台主機的連線與 model(以主機身分)。
    private var members: [HostSelection: HostMember] = [:]
    /// 主機頁的 Codex 啟動器(#274):每台主機一份，主機刪除時丟掉。
    private var codexLaunchers: [UUID: CodexLauncherModel] = [:]
    /// Demo 主機的主機寫入同意(Demo 不持久化，行為規格 F21)。
    private let demoConsent: any HostWriteConsentStore
    /// 真主機的主機寫入同意(以主機 id 為鍵);移除主機時清除。
    private let hostConsent: any HostWriteConsentStore
    /// 推播(後台、權限、配對紀錄);`nil` 時沒有推播。
    private let pushService: PushService?
    /// 帳號頁「通知裝置」(#266);沒有推播時是 `nil`。
    public let pushDevices: PushDevicesModel?
    /// 送出圖片的手機副本(泡泡顯示用;所有主機共用，檔名不重複)。
    private let attachmentStore: any AttachmentStore
    private let diagnostics: DiagnosticLog

    /// - Parameters:
    ///   - conversationCache: 對話快取(所有主機共用一個存放處，key 依主機分開)。
    ///   - preferences: 釘選、靜音等本機偏好(依主機分開：同一個 session 值在不同主機是不同的聊天)。
    ///   - hostIcons: 使用者替主機選的圖示。
    ///   - selectionStore: 選取中主機的存放處。
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
        currentHost currentHostStore: any CurrentHostStore = InMemoryCurrentHostStore(),
        planUsageSelection: any PlanUsageSelectionStore = InMemoryPlanUsageSelectionStore(),
        usageDisplay: UsageDisplaySetting = UsageDisplaySetting(),
        hostPicker hostPickerStore: any HostPickerStore = InMemoryHostPickerStore(),
        demoConsent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(),
        hostConsent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(), credentials: HostCredentials = HostCredentials(),
        hostService: HostServiceAccess = HostServiceAccess(),
        hostServiceUpdates: HostServiceUpdates = HostServiceUpdates(store: InMemoryHostServiceUpdateStore()),
        push pushService: PushService? = nil, tailscaleCheck: TailscaleCheckModel? = nil,
        attachmentStore: any AttachmentStore = FileAttachmentStore.app(),
        listMode: any AgentListModeStore = InMemoryAgentListModeStore(),
        offlineQueues: any OfflineQueueStore = InMemoryOfflineQueueStore(),
        diagnostics: DiagnosticLog = .system(category: "hosts"),
        publicModelCatalog: (any PublicModelCatalogFetching)? = nil,
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.store = store
        agentList = MergedAgentListModel(modeStore: listMode)
        self.selectionStore = selectionStore
        self.currentHostStore = currentHostStore
        self.planUsageSelection = planUsageSelection
        self.usageDisplay = usageDisplay
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
        pushDevices = pushService.map(PushDevicesModel.init(service:))
        self.tailscaleCheck = tailscaleCheck ?? TailscaleCheckModel()
        self.attachmentStore = attachmentStore
        self.diagnostics = diagnostics
        self.publicModelCatalog = publicModelCatalog
        offlineQueueStore = offlineQueues
        rebuildMembers()
        agentList.selectHost = { [weak self] host in self?.select(host) }
        agentList.enterDemo = { [weak self] in self?.enterDemo() }
        agentList.currentHostDidChange = { [weak self] host in self?.currentHostStore.save(host) }
    }

    /// Demo 主機在同意紀錄裡的主機 id。
    static let demoID = "demo"

    /// 選取中主機的 herdr client(設定頁讀 herdr 版本用)。
    public var herdrClient: HerdrClient { member(for: selection).client }
    /// 選取中主機的推播開關(#29)。
    public var push: PushModel { member(for: selection).push }
    /// 列表上每台主機的推播開關(依列表順序;spec #261:通知按主機管理，不綁選取中主機)。
    public var hostPushes: [HostPush] {
        listedHosts.compactMap { host in
            members[host].map {
                HostPush(
                    host: host, name: name(of: host), icon: icon(of: host), support: pushSupport(of: host),
                    installsViaHostService: usesHostService(host), hostServiceVersion: hostServiceVersion(of: host), model: $0.push)
            }
        }
    }
    /// 這支裝置已開啟通知的主機名稱(依列表順序);至少一台就算步驟卡的「開啟通知」完成。
    public var notifyingHostNames: [String] {
        hostPushes.notifyingHostNames
    }
    /// 選取中主機的主機主題(#23;DESIGN.md:選取中主機決定套用誰的主題)。每台主機各自一份、同意以主機為單位記住;
    /// 換選取中主機就換成那台的(讀過的主題留著，切回來不必等下一次輪詢)。
    public var hostTheme: HostThemeModel { member(for: selection).hostTheme }
    /// 選取中主機的「You should know」註記(設定頁撤掉修改用，#23)。每台主機各自一份，寫回的同意以主機為單位記住。
    public var youShouldKnow: YouShouldKnowModel { member(for: selection).youShouldKnow }

    /// 某台主機的主機設定(#274):主機頁(主機清單的 ⓘ)下方的主機主題、You should know、Codex 啟動器，作用在那台主機。
    /// 沒有這台主機時是 `nil`。
    public func hostSettings(for id: UUID) -> HostSettings? {
        guard hosts.contains(where: { $0.id == id }) else { return nil }
        let member = member(for: .host(id))
        // 畫面每次重繪都會呼叫：已有就不再寫回，否則改了被觀察的狀態會無限重繪。
        if let launcher = codexLaunchers[id] {
            return HostSettings(hostTheme: member.hostTheme, youShouldKnow: member.youShouldKnow, codexLauncher: launcher)
        }
        let launcher = CodexLauncherModel(host: CodexLauncherHost(channel: member.channel), hostID: id.uuidString, consent: hostConsent)
        codexLaunchers[id] = launcher
        return HostSettings(hostTheme: member.hostTheme, youShouldKnow: member.youShouldKnow, codexLauncher: launcher)
    }

    /// 數據用量頁的 model(#354):主機選單是 Demo 主機加上所有已存主機,標題的主機就是目前主機(#334),改它就是改目前主機。
    public func dataUsage() -> DataUsageModel {
        DataUsageModel(
            meter: trafficMeter ?? TrafficMeter(store: InMemoryTrafficStore()), hosts: hostOptions { _ in true }, currentHost: agentList.currentHost,
            currentHostChanged: { [weak self] in self?.agentList.currentHost = $0 })
    }

    /// 方案用量畫面的 model(#177):打開畫面時建立。主機選單是 Demo 主機加上所有已存主機，預設選取中主機。
    /// `host`、`agent` 有值時直接選那台與那個 Agent(用量區的「啟用用量顯示」導到這裡的同意流程)。
    public func planUsage(host: HostSelection? = nil, agent: PlanUsageAgent? = nil) -> PlanUsageModel {
        PlanUsageModel(
            hosts: hostOptions { _ in true }, fallback: selection, store: planUsageSelection, currentHost: host ?? agentList.currentHost,
            currentHostChanged: { [weak self] in self?.agentList.currentHost = $0 }, initialAgent: agent
        ) { [weak self] host, agent in
            self?.planUsageSource(host, agent)
        }
    }

    /// 用量區(#389):面板(單一 Agent)與主機 tab(Claude 與 Codex)共用。HTTPS 主機沒有來源,整區是「等主機服務支援」。
    public func usageSection(host: HostSelection, agents: [PlanUsageAgent]) -> UsageSectionModel {
        UsageSectionModel(hostName: name(of: host), agents: agents, display: usageDisplay) { [weak self] agent in
            self?.planUsageSource(host, agent)
        }
    }

    /// 方案用量的來源：Demo 主機是本機假資料(不耗 token 與傳輸);SSH 主機經主機通道;HTTPS 主機經主機服務(0.12.0 起)。
    private func planUsageSource(_ host: HostSelection, _ agent: PlanUsageAgent) -> PlanUsageSource? {
        let channel: any HostChannel
        let cost: PlanUsageQueryCost
        let hostID: String
        var files: HostFiles?
        switch host {
        case .demo:
            (channel, cost, hostID) = (demoChannel, .free, Self.demoID)
        case .host(let id):
            guard let configuration = hosts.first(where: { $0.id == id }) else { return nil }
            if case .https(let address) = configuration.connection {
                // HTTPS 主機經主機服務讀(0.12.0 起,#392);還沒配對或不是真的主機服務連線(UI 測試)沒有來源。
                guard !unpairedHostIDs.contains(id),
                    let connection = hostServiceConnection(for: configuration, address: address) as? HTTPSHostConnection
                else { return nil }
                return .hostService(
                    connection, agent: agent, hostID: id.uuidString, hostName: configuration.name, consent: hostConsent)
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
        let member = member(for: route.host)
        let client = member.client
        let paneID = route.paneID
        // 保留電腦版面時接上的格數:herdr 一接上就把 Pane 改成 handshake 的尺寸，所以要帶 Pane 目前的格數(#357)。
        return PaneTerminalModel(client: member.terminals, paneID: paneID, title: title, nativeSize: {
            (try? await client.snapshot())?.nativeSize(ofPane: paneID).map { TerminalGridSize(columns: $0.columns, rows: $0.rows) }
        })
    }

    /// 「⋯」選單要不要有登入 Shell 與檔案：有任何一台支援就有(挑選鈕能選;HTTPS 主機沒有，ADR-0010)。
    public var anyHostSupportsShell: Bool { !hostOptions { $0.supportsLoginShell }.isEmpty }

    /// 登入 Shell、檔案的主機挑選鈕(#245):只列支援的主機(HTTPS 主機沒有，ADR-0010),預設上次選的電腦或選取中主機。
    public func hostPicker(for scope: HostPickerScope) -> HostPickerModel {
        let options = hostOptions { $0.supportsLoginShell }
        return .remembering(scope, options: options, fallback: selection, store: hostPickerStore)
    }

    /// 檔案與主機 tab 頂列的主機選單(#390):只改選取中主機、不列「所有主機」,在那裡換主機不動聊天列表的篩選。
    /// 範例主機啟用前不列入。
    public func selectedHostPicker() -> HostPickerModel {
        HostPickerModel(options: hostOptions { _ in true }, preferred: [selection]) { [weak self] in
            self?.select($0)
        }
    }

    /// 選取中主機沒有登入 Shell 與檔案(HTTPS 主機,ADR-0010)。檔案 tab 顯示「不支援」。
    public var selectedHostSupportsFiles: Bool {
        guard case .host(let id) = selection, let host = hosts.first(where: { $0.id == id }) else { return true }
        return host.supportsLoginShell
    }

    /// 主機 tab 的單台主機總頁(#392):選取中主機的狀態與各區塊要不要出現;沒有主機可看時是 `nil`。
    public var overview: HostOverview? {
        if hasNoHostToShow { return nil }
        let selected = selection
        let configuration = selectedHost
        let list = agentList.list(for: selected)
        let herdrVersion = list?.snapshot?.version
        let id = configuration?.id
        let method = configuration?.connectionMethod
        let usesHostService = method?.usesHostService == true
        let status: HostOverview.Status
        if configuration == nil {
            status = .demo
        } else if let id, unpairedHostIDs.contains(id) {
            status = .needsPairing
        } else {
            switch list?.phase ?? .loading {
            case .loading: status = .connecting
            case .failed(let message): status = .offline(message: message, lastConnected: list?.updates.lastLoadedAt)
            case .loaded:
                if let herdrVersion, Self.isTooOld(herdr: herdrVersion) {
                    status = .herdrTooOld(version: herdrVersion)
                } else if let id, readOnlyHostIDs.contains(id) {
                    status = .readOnly
                } else {
                    status = .online
                }
            }
        }
        let pairedHostService = usesHostService && status != .needsPairing
        let hasUsageSource: Bool = switch status {
        case .demo, .needsPairing, .herdrTooOld: false
        case .connecting, .online, .readOnly, .offline: true
        }
        return HostOverview(
            host: selected, name: name(of: selected), icon: icon(of: selected), status: status, connection: method,
            herdrVersion: herdrVersion, address: configuration?.hostService?.description,
            showsUsage: hasUsageSource, showsHostService: pairedHostService,
            showsLoginShell: (configuration?.supportsLoginShell ?? true) && status != .needsPairing,
            canShare: configuration != nil, hasHostSettings: configuration != nil && status != .needsPairing,
            isSaved: configuration != nil)
    }

    /// herdr 低於 0.9.5(ADR-0002 的最低支援版本);看不懂的版本字串不算太舊。
    static func isTooOld(herdr version: String) -> Bool {
        guard let parsed = HostServiceVersion(version) else { return false }
        return parsed < HostServiceVersion(0, 9, 5)
    }

    /// 讀選取中 HTTPS 主機的唯讀狀態與主機服務版本(主機 tab 出現時);連不上的略過。
    public func refreshOverviewFacts() async {
        guard let host = selectedHost, case .https = host.connection, !unpairedHostIDs.contains(host.id),
            let connection = hostStatusConnection(for: host.id)
        else { return }
        if let readOnly = try? await connection.isReadOnlyDevice() {
            if readOnly { readOnlyHostIDs.insert(host.id) } else { readOnlyHostIDs.remove(host.id) }
        }
        if let version = try? await connection.hostServiceVersion() { hostServiceVersions[host.id] = version }
    }

    /// 沒有任何主機可看(沒有已存主機、也還沒進入範例主機):檔案與主機 tab 顯示空狀態。
    public var hasNoHostToShow: Bool { hosts.isEmpty && !demoEntered }

    /// 新增聊天的主機挑選鈕(#245):所有主機;預設聊天列表目前篩選的主機(#244),所有主機時用選取中主機。
    public func newChatHostPicker() -> HostPickerModel {
        .newChat(options: hostOptions { _ in true }, currentHost: agentList.currentHost, selection: selection)
    }

    /// 已啟用的範例主機(#394)加上符合條件的已存主機(主機挑選鈕與方案用量的主機選單)。
    private func hostOptions(_ isIncluded: (HostConfiguration) -> Bool) -> [HostOption] {
        (demoEntered ? [HostOption(id: .demo, name: name(of: .demo))] : [])
            + hosts.filter(isIncluded).map { HostOption(id: .host($0.id), name: $0.name, icon: icon(for: $0.id)) }
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
            // 標題列副標一律是聊天所在主機的名稱(#270)。
            hostName: { [weak self] in self?.name(of: route.host) },
            images: ComposerImages(uploader: member.uploader, store: attachmentStore),
            updates: member.list.updates,
            // 送出管線(#299):機密偵測在最前面(#302,只在本機判斷),再來是撤回倒數(#300),
            // 倒數結束時離線就排進那台主機的離線佇列(#301)。
            // 「做完再送」開著時排進主機的佇列(#305),不經撤回倒數與離線佇列。
            sendSteps: [
                SecretCheck(),
                SendWhenDoneStep(model: SendWhenDoneModel(host: member.sendWhenDoneHost, paneID: route.paneID)),
                UndoSendCountdown(seconds: { [weak self] in self?.undoSendSeconds() ?? 0 }),
                OfflineQueueStep(queue: offlineQueue(for: route.host)),
            ],
            // 模型目錄(#385):主機快取 → 公開目錄 → 內建對照表。
            modelCatalog: ModelCatalogResolver(host: SSHModelCatalogReader(channel: member.channel), publicCatalog: publicModelCatalog))
        // 註記屬於聊天所在的主機(#23):寫回也寫到那台。
        model.youShouldKnow = member.youShouldKnow
        // 圖片縮圖讀聊天所在的主機(#225)。
        model.agentFiles = member.agentFiles
        // 變更頁讀聊天所在主機的 git(#310)。
        model.gitChanges = member.gitChanges
        // context 取自聊天所在主機的 status line 檔(#388)。
        model.sessionStatusReader = member.sessionStatus
        model.onPromptDelivered = { [weak self] in self?.reviewPrompt?.promptDelivered() }
        // 離開期間摘要(#308):上次離開這個聊天的時間。
        model.awayStart = { [weak self] in self?.agentList.awayStart(for: route) }
        return model
    }

    /// 某台主機上的新增對話(#18;主機由新增聊天的主機挑選鈕決定，#245)。
    public func newChat(on host: HostSelection) -> NewChatModel {
        let member = member(for: host)
        // HTTPS 主機沒有主機通道：只收完整路徑(#287)。
        var usesHostService = false
        if case .host(let id) = host { usesHostService = hosts.first { $0.id == id }?.connectionMethod.usesHostService == true }
        let folders = usesHostService ? NewChatFolders.absolutePathsOnly : NewChatFolders(channel: member.channel)
        return NewChatModel(launcher: NewChatLauncher(client: member.client, folders: folders), folders: folders)
    }

    /// 新對話開始後：重讀列表，開那台主機上新 workspace 的 root pane 的聊天(行為規格 F3.2 第 5 步)。
    /// 把文字放進某個聊天的輸入框(草稿):新增聊天沒送出的第一則訊息(#272)。
    public func keepDraft(_ text: String, for route: ChatRoute) {
        member(for: route.host).drafts.save(text, chatKey: route.paneID, session: nil)
    }

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
            let update = hostServiceUpdate(for: host.id)
            let subtitle = host.ssh.map { "\($0.endpoint.username)@\($0.endpoint.host):\($0.endpoint.port)" }
                ?? host.hostService?.description ?? ""
            return HostRow(
                id: host.id, title: host.name, subtitle: subtitle, session: host.ssh?.herdr.session,
                isSelected: selection == .host(host.id), icon: icon(for: host.id), needsPairing: unpairedHostIDs.contains(host.id),
                hostServiceVersion: hostServiceVersions[host.id], hostServiceUpdate: update,
                hostServiceUpdateCommands: update.flatMap { _ in hostServiceVersions[host.id].map(HostServiceUpdates.commands(installed:)) })
        }
    }

    /// 讀每台已配對 HTTPS 主機的主機服務版本(主機清單出現時;已連線的主機不多花一個請求)與最新版本。連不上的略過;
    /// 沒有已配對的 HTTPS 主機時不查最新版本。最新版本這次取不到時沿用上次取到的。
    public func checkHostServiceVersions() async {
        let targets = hosts.compactMap { host -> (UUID, any HostConnection)? in
            guard case .https(let address) = host.connection, !unpairedHostIDs.contains(host.id) else { return nil }
            return (host.id, hostServiceConnection(for: host, address: address))
        }
        guard !targets.isEmpty else { return }
        // 與讀主機版本同時查：GitHub 慢或被擋時不拖住主機版本(推播區塊也靠它判斷功能)。
        async let latest = hostServiceUpdates.releases.latestVersion()
        for (id, connection) in targets {
            if let version = try? await connection.hostServiceVersion() { hostServiceVersions[id] = version }
        }
        if let latest = await latest { latestHostServiceVersion = latest }
    }

    /// 主機編輯頁的主機服務與已配對裝置區塊(#290、#291)用的連線：已配對的 HTTPS 主機才有。
    public func hostStatusConnection(for id: UUID) -> (any HostConnection)? {
        guard let host = hosts.first(where: { $0.id == id }), case .https(let address) = host.connection,
            !unpairedHostIDs.contains(id)
        else { return nil }
        return hostServiceConnection(for: host, address: address)
    }

    /// 不再提示這台主機更新到目前提示的版本(有更新的 Release 時再提示)。
    public func dismissHostServiceUpdate(for id: UUID) {
        guard let offered = hostServiceUpdate(for: id) else { return }
        dismissedHostServiceUpdates[id] = offered
        hostServiceUpdates.store.setDismissedVersion(offered, for: id)
    }

    private func hostServiceUpdate(for id: UUID) -> String? {
        guard let installed = hostServiceVersions[id],
            let offered = HostServiceUpdates.offeredVersion(installed: installed, latest: latestHostServiceVersion),
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
        // 存的目前主機已不在列表上(刪除或同步移除)就維持所有主機。
        if let stored = currentHostStore.load(), agentList.hostLabel(of: stored) != nil { agentList.currentHost = stored }
    }

    /// 選取主機並存起來。只改新聊天開在哪裡、列表排序與主機名標示、推播設定讀哪台;
    /// 不關閉、不重建任何連線(#39)。
    public func select(_ selection: HostSelection) {
        if case .host(let id) = selection, !hosts.contains(where: { $0.id == id }) { return }
        self.selection = selection
        selectionStore.save(selection)
        rebuildMembers()
    }

    /// 新增或編輯主機並儲存後：重讀清單並選取它。設定改了，那台主機的連線一律關閉重建。
    public func didSave(_ host: HostConfiguration) {
        changeRecorder?.hostSaved(host.id)
        hosts = (try? sortedHosts()) ?? hosts
        refreshPairing()
        dropChannel(of: host.id)
        members[.host(host.id)] = nil
        codexLaunchers[host.id] = nil
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
                codexLaunchers[host.id] = nil
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
        codexLaunchers[id] = nil
        // 刪配對要再連一次主機：祕密刪掉前先讀出來，給刪配對用的連線。
        let secret = try? credentials.secrets.secret(for: id)
        let deviceToken = try? hostService.tokens.deviceToken(for: id)
        try credentials.secrets.setSecret(nil, for: id)
        try hostService.tokens.setDeviceToken(nil, for: id)
        try store.delete(id)
        if let removed, let settings = removed.ssh {
            forgetPush(of: removed, settings: settings, secret: secret)
            if hostConsent.isGranted(AuthorizedKeyInstaller.feature.id, host: id.uuidString) {
                restoreDeviceKey(on: removed, settings: settings, secret: secret)
            }
        } else if let removed, let address = removed.hostService, let deviceToken {
            // 先刪推播配對再撤銷權杖;主機離線時權杖留在主機上，可在主機上撤銷。
            forgetHostServicePush(of: removed, address: address, deviceToken: deviceToken)
        }
        hostConsent.revokeAll(host: id.uuidString)
        // 刪除主機也清掉它的離線佇列(#301)。
        offlineQueues[.host(id)] = nil
        offlineQueueStore.save([], host: HostSelection.host(id).storedValue)
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

    /// 點了推播通知：開配對主機上該 Agent 的聊天;主機服務通知回傳要開編輯頁的主機。所有主機都在同一個列表，所以不改選取中主機。
    /// 不認得的配對(主機已移除)不動。
    @discardableResult
    public func open(_ route: PushRoute, pairings: any PushPairingStore) -> PushDestination? {
        if route.event == PushRoute.testEvent { return nil }
        guard let hostID = pairings.host(forKeyHash: route.keyHash), let id = UUID(uuidString: hostID),
              hosts.contains(where: { $0.id == id }) else { return nil }
        if route.event != nil { return .hostEditor(id) }
        guard let paneID = route.paneID else { return nil }
        let chat = ChatRoute(host: .host(id), paneID: paneID)
        agentList.openedChat = chat
        return .chat(chat)
    }

    /// 啟動時：這支裝置被別支關閉了就把「通知」區塊改回關閉，之後才補註冊(APNs token 換了、舊版 app 的配對)。
    public func refreshPushRegistrations() async {
        await pushService?.refreshAtLaunch()
    }

    /// 點了推播通知(用 app 的推播紀錄)。
    @discardableResult
    public func open(_ route: PushRoute) -> PushDestination? {
        guard let pushService else { return nil }
        return open(route, pairings: pushService.store)
    }

    /// 新增主機(`editing` 為 `nil`)或編輯既有主機的畫面 model。`method`:新增時預選的連線方式。
    public func makeEditor(editing: HostConfiguration? = nil, method: HostConfiguration.ConnectionMethod? = nil) -> HostEditorModel {
        let editor = HostEditorModel(
            store: store, editing: editing, credentials: credentials, hostService: hostService,
            icon: editing.map { icon(for: $0.id) } ?? .default, saveIcon: setIcon(_:for:),
            renameHost: { [weak self] id, name in try self?.rename(id, to: name) }, makeChannel: makeChannel)
        if editing == nil, let method { editor.connectionMethod = method }
        editor.attachTraffic(trafficProvider)
        return editor
    }

    /// 引導最後一頁判斷有沒有 Purrdr Plus 用的檢查(同推播開關:重讀後台後的結果)。沒有推播服務就當沒有。
    private var guidePlusCheck: @MainActor () async -> Bool {
        { [pushService] in
            guard let pushService else { return false }
            return await pushService.isPlusActive()
        }
    }

    /// 所有新增入口(歡迎頁、主機清單「＋」、「⋯」選單)開的新增主機引導(#341)。
    public func makeAddHostGuide() -> AddHostGuideModel {
        let guide = AddHostGuideModel(
            store: store, credentials: credentials, hostService: hostService, isPlusActive: guidePlusCheck, makeChannel: makeChannel)
        guide.attachTraffic(trafficProvider)
        return guide
    }

    /// 連線測試、配對與撤銷等「還沒有連線」的流量依主機 id 記進數據用量(#353);沒有計量時不記。
    private var trafficProvider: (UUID) -> TrafficRecording {
        { [trafficMeter] id in trafficMeter?.recorder(for: id.uuidString) ?? { _, _ in } }
    }

    /// 匯入連結(主機分享連結、配對 QR code)開的引導,資料已齊時直接到測試連線(#344);引導接不了(原生 SSH、壞連結)時丟錯。
    public func makeImportGuide(_ url: URL) throws -> AddHostGuideModel {
        let guide = try AddHostGuideModel(
            store: store, credentials: credentials, hostService: hostService, isPlusActive: guidePlusCheck, makeChannel: makeChannel,
            shortcut: .importLink(url))
        guide.attachTraffic(trafficProvider)
        return guide
    }

    /// 同步來、這支裝置還沒配對的 HTTPS 主機:直接到配對步驟(#344)。
    public func makePairingGuide(for host: HostConfiguration) throws -> AddHostGuideModel {
        let guide = try AddHostGuideModel(
            store: store, credentials: credentials, hostService: hostService, isPlusActive: guidePlusCheck, makeChannel: makeChannel,
            shortcut: .needsPairing(host))
        guide.attachTraffic(trafficProvider)
        return guide
    }

    /// 沒有已存主機時，列表要不要直接列出 Demo(#332)。預設 true(測試與預覽);app 正式啟動設 false，
    /// 這時沒有主機就顯示空狀態，按「試用 Demo」或在主機清單選 Demo 才進入。
    public var demoEntered = true {
        didSet {
            agentList.isAwaitingFirstHost = hosts.isEmpty && !demoEntered
            if oldValue != demoEntered { demoEnteredDidChange?(demoEntered) }
        }
    }

    /// 範例主機啟用或移除時通知(app 記下來,重開後保持)。
    public var demoEnteredDidChange: (@MainActor (Bool) -> Void)?

    /// 移除範例主機(主機 tab 的「移除範例主機」):不再列入各主機選單;選取中的是它就回到已存主機。
    public func removeDemo() {
        demoEntered = false
        if selection == .demo { select(validSelection(nil)) } else { rebuildMembers() }
    }

    /// 進入 Demo 主機。
    public func enterDemo() {
        demoEntered = true
        select(.demo)
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
        // 沒有網路時列表立刻顯示離線，不等連線逾時(#221)。
        agentList.isNetworkAvailable = !simulatesNoNetwork && signature.hasPrefix("satisfied")
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

    /// UI 測試情境：裝置一直沒有網路(`-demoNoNetwork`,#221)。
    public var simulatesNoNetwork = false {
        didSet { if simulatesNoNetwork { agentList.isNetworkAvailable = false } }
    }
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
        default:
            // 還沒配對的 HTTPS 主機連不上，有其他主機時不預設選它。
            let preferred = hosts.first { !unpairedHostIDs.contains($0.id) } ?? hosts.first
            return preferred.map { .host($0.id) } ?? .demo
        }
    }

    private func pushSupport(of host: HostSelection) -> HostPushSupport {
        guard case .host(let id) = host, let configuration = hosts.first(where: { $0.id == id }) else { return .demoHost }
        // 沒有裝置權杖連不上主機服務：先說明要配對(#295),配對後才看得到能不能裝。
        guard !unpairedHostIDs.contains(id) else { return .needsPairing }
        guard members[host]?.push.isAvailable == true else { return .unsupported }
        // 版本還不知道(還沒連上)時先當可開：開啟時主機服務太舊會說明要更新。
        guard configuration.connectionMethod.usesHostService, let installed = hostServiceVersions[id],
              !HostServiceFeature.pushPlugin.isAvailable(onHostServiceVersion: installed)
        else { return .supported }
        return .needsHostService(
            version: HostServiceFeature.pushPlugin.minimumVersion.description, update: HostServiceUpdates.commands(installed: installed))
    }

    private func hostServiceVersion(of host: HostSelection) -> HostServiceVersion? {
        guard case .host(let id) = host else { return nil }
        return hostServiceVersions[id].flatMap(HostServiceVersion.init)
    }

    private func usesHostService(_ host: HostSelection) -> Bool {
        guard case .host(let id) = host else { return false }
        return hosts.first { $0.id == id }?.connectionMethod.usesHostService == true
    }

    private func icon(of host: HostSelection) -> HostIcon {
        guard case .host(let id) = host else { return .default }
        return companion(id)?.icon ?? icon(for: id)
    }

    private func companion(_ id: UUID) -> DemoCompanionHost? {
        demoCompanions.first { $0.id == id }
    }

    /// 列表上的主機：所有已存主機(依名稱);Demo 主機與它的示範主機(#34)只在沒有已存主機或選了 Demo 時。
    private var listedHosts: [HostSelection] {
        var wanted: [HostSelection] = hosts.map { .host($0.id) }
        if hosts.isEmpty || selection == .demo { wanted.insert(contentsOf: [.demo] + demoCompanions.map { .host($0.id) }, at: 0) }
        return wanted
    }

    /// 依列表上的主機重建成員;已有的成員沿用(連線、列、草稿不重建)。
    private func rebuildMembers() {
        let wanted = listedHosts
        members = members.filter { wanted.contains($0.key) }
        for host in wanted where members[host] == nil { members[host] = makeMember(host) }
        let sources = wanted.compactMap { host in
            members[host].map { member in
                MergedAgentListModel.Source(
                    host: host, name: name(of: host), icon: icon(of: host), list: member.list, actions: member.actions,
                    notes: member.youShouldKnow)
            }
        }
        agentList.isAwaitingFirstHost = hosts.isEmpty && !demoEntered
        agentList.update(sources: sources, selected: selection)
    }

    /// 某台主機的離線佇列(#301):第一次用到時從本機讀回。補送前以新鮮的快照確認 Agent 目前的狀態。
    public func offlineQueue(for host: HostSelection) -> OfflineQueue {
        if let queue = offlineQueues[host] { return queue }
        let queue = OfflineQueue(host: host.storedValue, store: offlineQueueStore) { [weak self] text, agent, expectedSession in
            guard let client = self?.member(for: host).client else { return .rejected(message: "") }
            let fresh = (try? await client.snapshot())?.agents.first { $0.paneID == agent.paneID } ?? agent
            // 重讀的快照 session 已不是排入時的:什麼都不送(HTTPS 主機另在送出前比對)。
            if let expectedSession, let session = fresh.sessionID, session != expectedSession { return .paneChanged }
            return await PromptDelivery(client: client).send(text, to: fresh, expectedSession: expectedSession)
        }
        offlineQueues[host] = queue
        return queue
    }

    /// 某台主機的成員;不在列表上時(例如剛刪除的主機還開著的畫面)暫時建一個不保留的。
    private func member(for host: HostSelection) -> HostMember {
        members[host] ?? makeMember(host)
    }

    private func makeMember(_ host: HostSelection) -> HostMember {
        let member = makeMemberConnections(host)
        // 主機更新來源讀到的 Agent 列表交給離線佇列(#301):重連後的第一份就補送。
        let queue = offlineQueue(for: host)
        member.list.updates.onSnapshot = { [weak queue] snapshot in queue?.receive(snapshot) }
        return member
    }

    private func makeMemberConnections(_ host: HostSelection) -> HostMember {
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
                files: (connection as? any HostFileFetching) ?? UnsupportedHostFileFetcher(), uploads: connection as? any HostUploading,
                // 變更頁走主機服務的 git.status／git.diff(#310);UI 測試的替身連線沒有。
                git: (connection as? any GitChangesReading) ?? UnsupportedGitChanges(),
                preferences: preferences.store(for: host),
                push: pushService, consent: hostConsent)
        case .tailscaleSSH(let settings), .openSSH(let settings, _):
            return HostMember(
                host: host, configuration: configuration, channel: channel(for: configuration, settings: settings),
                preferences: preferences.store(for: host), push: pushService, consent: hostConsent)
        }
    }

    private func hostServiceConnection(for host: HostConfiguration, address: HostServiceAddress) -> any HostConnection {
        if let connection = hostServiceConnections[host.id] { return connection }
        let connection = hostService.connection(for: host, address: address)
        if let meter = trafficMeter { (connection as? HTTPSHostConnection)?.attachTraffic(meter.recorder(for: host.id.uuidString)) }
        hostServiceConnections[host.id] = connection
        return connection
    }

    private func channel(for host: HostConfiguration, settings: HostConfiguration.SSHSettings) -> any HostChannel {
        if let channel = channels[host.id] { return channel }
        // Windows 主機的指令換成 PowerShell 方言(#26);其他原樣。作業系統未知(主機同步帶來的新主機)時先偵測，
        // 不對可能是 Windows 的主機送 POSIX 指令。
        let base = makeChannel(settings.endpoint, settings.hostKeyPin, credentials.provider(for: host))
        if let meter = trafficMeter { (base as? SSHHostChannel)?.attachTraffic(meter.recorder(for: host.id.uuidString)) }
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
        let channel = makeChannel(settings.endpoint, settings.hostKeyPin, provider)
        if let meter = trafficMeter { (channel as? SSHHostChannel)?.attachTraffic(meter.recorder(for: host.id.uuidString)) }
        // 這條連線是刪除主機時另開的，不在任何地方重用：刪完配對就關閉。
        pushService.forget(
            hostID: host.id.uuidString, installer: pushService.sshInstaller(channel: channel, herdr: settings.herdr)
        ) {
            await channel.disconnect()
        }
    }

    /// 用密碼加入的公鑰(#285):另開一條連線還原 `authorized_keys`(ADR-0002),不等待;主機離線時留在主機上。
    private func restoreDeviceKey(on host: HostConfiguration, settings: HostConfiguration.SSHSettings, secret: HostSecret?) {
        let deviceKey = credentials.deviceKey
        let provider = credentials.provider(
            method: host.connectionMethod, authentication: host.authentication, hostID: nil, entered: secret)
        let base = makeChannel(settings.endpoint, settings.hostKeyPin, provider)
        if let meter = trafficMeter { (base as? SSHHostChannel)?.attachTraffic(meter.recorder(for: host.id.uuidString)) }
        let channel = host.operatingSystem?.channel(base) ?? OperatingSystemDetectingChannel(base) { _ in }
        let diagnostics = diagnostics
        Task {
            do {
                try await AuthorizedKeyInstaller(channel: channel).restore(try deviceKey.publicKey())
            } catch {
                diagnostics.error("Couldn’t remove this device’s key from host \(host.id): \(error)")
            }
            await base.disconnect()
        }
    }

    /// HTTPS 主機的推播配對：以讀出的權杖另開一條連線刪掉配對，之後撤銷權杖並關閉連線。沒有配對時直接撤銷。
    private func forgetHostServicePush(of host: HostConfiguration, address: HostServiceAddress, deviceToken: String) {
        let pairing = hostService.pairing
        let recorder = trafficMeter?.recorder(for: host.id.uuidString)
        guard let pushService, pushService.store.keyHash(forHost: host.id.uuidString) != nil,
              let connection = hostService.makeConnection(address, { deviceToken }) as? HTTPSHostConnection
        else {
            hostService.revokeWithoutWaiting(deviceToken, at: address, traffic: recorder)
            return
        }
        connection.attachTraffic(recorder)
        pushService.forget(hostID: host.id.uuidString, installer: pushService.hostServiceInstaller(connection: connection)) {
            await connection.disconnect()
            try? await pairing.revoke(address: address, deviceToken: deviceToken, traffic: recorder)
        }
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

/// 一台主機能不能開通知。
public enum HostPushSupport: Equatable, Sendable {
    case supported
    /// Demo 主機與示範主機。
    case demoHost
    /// 這支裝置還沒配對的 HTTPS 主機(例如主機同步帶來的,#295):配對後就能開。
    case needsPairing
    /// 這台主機沒有推播外掛安裝(例如 HTTPS 主機取不到主機服務連線)。
    case unsupported
    /// HTTPS 主機要這版以上的主機服務代裝外掛;附依已安裝版本的更新指令。
    case needsHostService(version: String, update: HostServiceUpdateCommands)
}

@MainActor
extension [HostPush] {
    /// 已開啟通知的主機名稱(依列表順序)。
    public var notifyingHostNames: [String] {
        // `&&` 的右邊是 nonisolated autoclosure,不能讀 main actor 的 state。
        filter { hostPush in
            guard hostPush.support == .supported else { return false }
            return hostPush.model.state == .on
        }.map(\.name)
    }
}

/// 點通知後開了什麼。
public enum PushDestination: Equatable, Sendable {
    /// 開了這個 Agent 的聊天。
    case chat(ChatRoute)
    /// 要開這台主機的編輯頁(主機服務通知);由畫面開主機 sheet。
    case hostEditor(UUID)
}

/// 一台主機的推播開關(帳號頁「通知」區塊的一列)。
public struct HostPush: Identifiable {
    public let host: HostSelection
    public let name: String
    public let icon: HostIcon
    public let support: HostPushSupport
    /// HTTPS 主機：由主機服務代裝外掛(不是 SSH)。
    public let installsViaHostService: Bool
    /// HTTPS 主機回報的主機服務版本(還沒連上、看不懂或 SSH 主機是 `nil`);較新的通知種類依它判斷能不能選(#311)。
    public var hostServiceVersion: HostServiceVersion? = nil
    public let model: PushModel

    public var id: HostSelection { host }

    /// 這台主機能不能送測試通知:HTTPS 主機要主機服務 0.11.0 以上(版本還不知道就先不提供)。
    public var supportsTestNotification: Bool {
        guard installsViaHostService else { return true }
        return hostServiceVersion.map { $0 >= HostServiceFeature.pushTest.minimumVersion } ?? false
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
    /// 聊天附加的圖片與檔案上傳到主機(#286)。
    let uploader: any HostUploading
    /// 變更頁的唯讀 git 讀取(#310)。
    let gitChanges: any GitChangesReading
    /// 各 session 的 Claude status line 狀態(#388):SSH 讀主機上的 session 檔,HTTPS 走主機服務的 `usage.session_context`。
    let sessionStatus: any ClaudeSessionStatusReading
    /// 主機上的 Send When Done 佇列(#305);只有 HTTPS 主機(主機服務)有，其他是 `nil`。
    let sendWhenDoneHost: (any SendWhenDoneHosting)?

    /// - Parameters:
    ///   - connection: 上層功能用的主機連線;`nil` 時是包住 `channel` 的 SSH 連線。
    ///   - files: 主機取檔;`nil` 時經 `channel` 跑 SSH 的取檔腳本(主機跑不了時是 unsupported)。
    ///   - git: 變更頁的 git 讀取;`nil` 時經 `channel` 跑唯讀 git 指令(#310)。
    ///   - uploads: 上傳到主機;`nil` 時經 `channel` 的 exec＋stdin(Windows 主機由 `WindowsHostChannel` 換成 PowerShell 版，#68)。
    init(
        host: HostSelection, configuration: HostConfiguration?, channel: any HostChannel, connection: (any HostConnection)? = nil,
        files: (any HostFileFetching)? = nil, uploads: (any HostUploading)? = nil, git: (any GitChangesReading)? = nil,
        preferences: any ChatPreferencesStore, push pushService: PushService?,
        consent: any HostWriteConsentStore
    ) {
        self.host = host
        self.channel = channel
        uploader = uploads ?? SSHHostUploader(channel: channel)
        gitChanges = git ?? SSHGitChanges(channel: channel)
        sendWhenDoneHost = configuration?.connectionMethod.usesHostService == true ? connection as? any SendWhenDoneHosting : nil
        let herdr = configuration?.ssh?.herdr ?? HerdrInstallation()
        let connection = connection ?? SSHHostConnection(
            channel: channel, herdr: herdr, followDiagnostics: DiagnosticLog.systemNotice(category: "transcript-follow"))
        client = HerdrClient(connection: connection)
        transcripts = TranscriptReader(connection: connection)
        terminals = PaneTerminalClient(connection: connection)
        let list = AgentListModel(client: client, transcripts: transcripts, host: host)
        self.list = list
        actions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await list.load() })
        // HTTPS 主機經主機服務代裝(取不到主機服務連線就沒有，列上標成不支援);其他經 SSH。
        let installer: (any PushPluginInstalling)? = if configuration?.connectionMethod.usesHostService == true {
            (connection as? any PushPluginInstallerProviding)?.pushPluginInstallers().flatMap { makeInstaller in pushService?.installer(makeInstaller) }
        } else {
            pushService?.sshInstaller(channel: channel, herdr: herdr)
        }
        let push = PushModel(service: pushService, hostID: configuration?.id.uuidString, installer: installer) {
            preferences.load().muted
        }
        self.push = push
        // 測試通知(#328):SSH 主機由主機上的腳本送(與外掛同一條路:主機 → 後台 → APNs);HTTPS 主機還沒有，Demo 主機沒有真的外掛。
        // Windows 也有 PowerShell 版,所以不分作業系統。
        if let configuration, let pushService, !configuration.connectionMethod.usesHostService {
            push.testSender = SSHPushTestSender(service: pushService, channel: channel, hostName: configuration.name)
        }
        // HTTPS 主機經主機服務的 `push.test`(0.11.0 起;版本不足時列上不顯示按鈕,見 `HostPush.supportsTestNotification`)。
        if let configuration, let pushService, configuration.connectionMethod.usesHostService, let https = connection as? HTTPSHostConnection {
            push.testSender = HostServicePushTestSender(service: pushService, connection: https, hostName: configuration.name)
        }
        actions.mutedChanged = { muted in Task { await push.syncMuted(muted) } }
        let hostID = configuration?.id.uuidString ?? HostsModel.demoID
        let hostFiles = HostFiles.longRunning(channel: channel, diagnostics: DiagnosticLog.systemNotice(category: "host-files"))
        self.hostFiles = hostFiles
        sessionStatus = configuration?.connectionMethod.usesHostService == true
            ? (connection as? any ClaudeSessionStatusReading) ?? UnavailableSessionStatus()
            : ClaudePlanUsageHost(channel: channel, files: hostFiles)
        // 點開的檔案依主機分資料夾，刪除主機時一起清(#228)。
        agentFiles = AgentFileLoads(
            fetcher: files ?? SSHHostFileFetcher(channel: channel, diagnostics: DiagnosticLog.systemNotice(category: "host-file-fetch")),
            downloadDirectory: AgentFileLoads.defaultDownloadDirectory.appending(path: hostID, directoryHint: .isDirectory))
        youShouldKnow = YouShouldKnowModel(host: YouShouldKnowHost(channel: channel, files: hostFiles), hostID: hostID, consent: consent)
        hostTheme = HostThemeModel(host: HostThemeHost(channel: channel, files: hostFiles), hostID: hostID, consent: consent)
    }
}

/// 取不到主機服務連線(UI 測試的替身連線)時沒有 session 狀態,context 用對話紀錄算法(#388)。
struct UnavailableSessionStatus: ClaudeSessionStatusReading {
    func sessionStatuses(sessionIDs: [String]) async throws -> [String: ClaudeSessionStatus] { [:] }
}

/// 經 SSH 在主機上送測試通知(#328);每次才讀這支裝置的推播 id。
struct SSHPushTestSender: PushTestNotificationSending {
    let service: PushService
    let channel: any HostChannel
    let hostName: String

    func sendTest(hostID: String) async throws {
        let deviceID = try await service.device().id
        try await SSHPushTestNotifier(channel: channel, deviceID: deviceID, hostName: hostName).send()
    }
}

/// 經主機服務送測試通知(#328、`push.test`);每次才讀這支裝置的推播 id。
struct HostServicePushTestSender: PushTestNotificationSending {
    let service: PushService
    let connection: HTTPSHostConnection
    let hostName: String

    func sendTest(hostID: String) async throws {
        let deviceID = try await service.device().id
        try await HostServicePushTestNotifier(connection: connection, deviceID: deviceID, hostName: hostName).send()
    }
}

extension PushService {
    /// 這支裝置經主機服務(HTTPS 主機)的推播外掛安裝。
    public func hostServiceInstaller(connection: HTTPSHostConnection) -> any PushPluginInstalling {
        installer { HostServicePushPluginInstaller(connection: connection, deviceID: $0) }
    }

    /// 這支裝置經 SSH 的推播外掛安裝。
    public func sshInstaller(channel: any HostChannel, herdr: HerdrInstallation) -> any PushPluginInstalling {
        let pluginSource = configuration.pluginSource
        return installer { SSHPushPluginInstaller(channel: channel, herdr: herdr, deviceID: $0, pluginSource: pluginSource) }
    }
}

/// 一台主機的主機設定(#274):在主機頁下方，作用在那台主機。
@MainActor
public struct HostSettings: Equatable {
    public let hostTheme: HostThemeModel
    public let youShouldKnow: YouShouldKnowModel
    public let codexLauncher: CodexLauncherModel

    public nonisolated static func == (lhs: HostSettings, rhs: HostSettings) -> Bool {
        lhs.hostTheme === rhs.hostTheme && lhs.youShouldKnow === rhs.youShouldKnow && lhs.codexLauncher === rhs.codexLauncher
    }
}


/// 主機 tab 的單台主機總頁(#392):目前選取主機的狀態與各區塊要不要出現。
public struct HostOverview: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// 範例主機:不連任何電腦。
        case demo
        case connecting
        case online
        /// 線上,但這支裝置以唯讀權杖配對:不能送出或回答。
        case readOnly
        /// 讀不到(主機離線或不在 Tailscale 上);`lastConnected` 是最後一次讀到的時間。
        case offline(message: String, lastConnected: Date?)
        /// HTTPS 主機在這支裝置還沒有裝置權杖。
        case needsPairing
        /// herdr 低於 0.9.5。
        case herdrTooOld(version: String)
    }

    public var host: HostSelection
    public var name: String
    public var icon: HostIcon
    public var status: Status
    /// 連線方式;範例主機是 `nil`。
    public var connection: HostConfiguration.ConnectionMethod?
    /// 主機上 herdr 回報的版本(讀到快照之後)。
    public var herdrVersion: String?
    /// HTTPS 主機的主機服務位址。
    public var address: String?
    public var showsUsage: Bool
    /// 已配對 HTTPS 主機:主機服務版本、更新與已配對裝置。
    public var showsHostService: Bool
    public var showsLoginShell: Bool
    public var canShare: Bool
    /// 主機主題、You should know、Codex 啟動器與用量擷取。
    public var hasHostSettings: Bool
    /// 已存的主機(可編輯、移除);範例主機不是。
    public var isSaved: Bool
}
