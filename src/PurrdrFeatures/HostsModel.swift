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
    /// 主機同步改了位址或 host key(#572):要使用者重新確認才連線。
    public var needsReconfirmation: Bool
    /// HTTPS 主機目前的主機服務版本(讀到之前、SSH 主機是 `nil`,#362)。
    public var hostServiceVersion: String?
    /// HTTPS 主機的主機服務比最新 Release 舊：可更新到的版本(#198)。
    public var hostServiceUpdate: String?
    /// 有可更新版本時，依這台主機已安裝的版本要執行的更新指令。
    public var hostServiceUpdateCommands: HostServiceUpdateCommands?

    public init(
        id: UUID, title: String, subtitle: String, session: String?, isSelected: Bool, icon: HostIcon = .default,
        needsPairing: Bool = false, needsReconfirmation: Bool = false, hostServiceVersion: String? = nil, hostServiceUpdate: String? = nil,
        hostServiceUpdateCommands: HostServiceUpdateCommands? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.session = session
        self.isSelected = isSelected
        self.icon = icon
        self.needsPairing = needsPairing
        self.needsReconfirmation = needsReconfirmation
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
    public private(set) var loadError: DisplayedError?
    /// Tailscale SSH check mode 的提示。所有主機通道共用;composition root 把它的 `observer` 交給主機通道。
    public let tailscaleCheck: TailscaleCheckModel
    /// 使用者新增、修改、刪除主機時通知(主機同步)。
    public weak var changeRecorder: (any HostChangeRecorder)?
    /// 對話作答的觸覺(composition root 注入系統觸覺;測試不播放)。
    public var haptics: any Haptics = SilentHaptics()
    /// 數據用量的流量計量(#353):建立主機連線時接上(之後建的連線才算;app 啟動時就設好)。
    public var trafficMeter: TrafficMeter?
    /// 新增聊天／續接的步驟與 SSH 關鍵請求的耗時(#635);由 composition root 接到診斷記錄，在載入主機(建立連線)前設定。
    public var operationTimings: OperationTimingSink?
    /// 成功送出幾次 prompt 後請求評分(#34);`nil` 時不請求。所有主機、所有聊天共用一份計數。
    public var reviewPrompt: ReviewPrompt?
    /// 送出可撤回的秒數(#300),每次送出時讀;預設讀本機偏好(設定頁改的那一個)。
    @ObservationIgnored public var undoSendSeconds: @MainActor () -> Int = { UndoSendSettings.seconds(in: .standard) }

    let store: any HostStore
    /// 離線佇列存放處(#301);每台主機一份佇列，同一台的聊天共用。
    private let offlineQueueStore: any OfflineQueueStore
    private var offlineQueues: [HostSelection: OfflineQueue] = [:]
    private let selectionStore: any HostSelectionStore
    private let currentHostStore: any CurrentHostStore
    /// 方案用量畫面上次選的主機與 Agent。
    let planUsageSelection: any PlanUsageSelectionStore
    /// 用量的「已用／剩餘」全域設定(#389):用量區、方案用量頁、context 與設定共用同一份。
    public let usageDisplay: UsageDisplaySetting
    /// 登入 Shell、檔案上次選的電腦(#245)。
    let hostPickerStore: any HostPickerStore
    private let demoChannel: any HostChannel
    /// Demo 主機的主機取檔(#225;composition root 給 Demo 的 adapter,Features 不 import Demo)。
    private let demoFiles: any HostFileFetching
    /// Demo 的示範主機(#34)。
    private let demoCompanions: [DemoCompanionHost]
    let makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    let credentials: HostCredentials
    /// HTTPS 主機的裝置權杖、連線配對與主機連線(ADR-0010)。
    let hostService: HostServiceAccess
    private let conversationCache: any ConversationCache
    private let preferences: any HostChatPreferencesStore
    private let hostIcons: any HostIconStore
    /// 已存主機的圖示(從 `hostIcons` 讀出)。是 observable 狀態：改了圖示，依賴它的畫面(主機清單、主機鈕)重新計算。
    private var icons: [UUID: HostIcon] = [:]
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
    /// 三種連線方式的 adapter(#563):能力組、連線重用、流量計量與刪除收尾都在這裡。
    private var sshAdapter: SSHHostAdapter!
    private var httpsAdapter: HTTPSHostAdapter!
    private var demoAdapter: DemoHostAdapter!
    /// 列表上每台主機的連線與 model(以主機身分)。
    private var members: [HostSelection: HostMember] = [:]
    /// 依 Agent 種類接上主機能力的對照表(#443)。
    private let agentHostServices = AgentHostServices()
    /// Demo 主機的主機寫入同意(Demo 不持久化，行為規格 F21)。
    private let demoConsent: any HostWriteConsentStore
    /// 真主機的主機寫入同意(以主機 id 為鍵);移除主機時清除。
    private let hostConsent: any HostWriteConsentStore
    /// 推播(後台、權限、配對紀錄);`nil` 時沒有推播。
    private let pushService: PushService?
    /// 帳號頁「通知裝置」(#266);沒有推播時是 `nil`。
    public let pushDevices: PushDevicesModel?
    /// 「通知」頁的今日推播用量(#677)。
    public let pushUsage: PushUsageModel?
    /// 送出圖片的手機副本(泡泡顯示用;所有主機共用，檔名不重複)。
    private let attachmentStore: any AttachmentStore
    private let diagnostics: DiagnosticLog
    /// 診斷事件(#688):網路切換、回前景的重撥決策等記進可分享的診斷檔;組合根設定,沒設定就不記。
    public var diagnosticEvents: DiagnosticEvents = .discarding
    /// 等待(HTTPS 偵測 Agent 的重試間隔);測試注入。
    private let sleep: Sleep
    /// 各清單骨架的列數(上次的數量,#496)。
    private let skeletonRowCounts: any SkeletonRowCountStore

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
    package init(
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
        skeletonRowCounts: any SkeletonRowCountStore = InMemorySkeletonRowCountStore(),
        offlineQueues: any OfflineQueueStore = InMemoryOfflineQueueStore(),
        diagnostics: DiagnosticLog = .system(category: "hosts"),
        publicModelCatalog: (any PublicModelCatalogFetching)? = nil, sleep: @escaping Sleep = Sleeping.task,
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.store = store
        self.sleep = sleep
        self.skeletonRowCounts = skeletonRowCounts
        agentList = MergedAgentListModel(skeletonRowCounts: skeletonRowCounts)
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
        pushUsage = pushService.map(PushUsageModel.init(service:))
        self.tailscaleCheck = tailscaleCheck ?? TailscaleCheckModel()
        self.attachmentStore = attachmentStore
        self.diagnostics = diagnostics
        self.publicModelCatalog = publicModelCatalog
        offlineQueueStore = offlineQueues
        let environment = HostAdapterEnvironment(
            makeChannel: makeChannel, credentials: credentials, hostService: hostService, pushService: pushService,
            traffic: HostTrafficWiring(meter: { [weak self] in self?.trafficMeter }), diagnostics: diagnostics,
            recordOperatingSystem: { [weak self] operatingSystem, id in self?.recordOperatingSystem(operatingSystem, for: id) },
            consent: hostConsent, operationTimings: { [weak self] in self?.operationTimings })
        sshAdapter = SSHHostAdapter(environment: environment)
        httpsAdapter = HTTPSHostAdapter(environment: environment)
        demoAdapter = DemoHostAdapter(channel: demoChannel, files: demoFiles, consent: demoConsent)
        memberEnvironment = HostMemberEnvironment(
            hostName: { [weak self] in self?.name(of: $0) ?? "" },
            enabledAgents: { [weak self] in self?.enabledAgents(on: $0) ?? Set(HostAgentSettings.configurable) },
            isSavedHost: { [weak self] id in self?.hosts.contains { $0.id == id } ?? false },
            conversationCache: conversationCache,
            haptics: { [weak self] in self?.haptics ?? SilentHaptics() },
            attachmentStore: attachmentStore,
            trafficMeter: { [weak self] in self?.trafficMeter },
            operationTimings: { [weak self] in self?.operationTimings },
            undoSendSeconds: { [weak self] in self?.undoSendSeconds() ?? 0 },
            publicModelCatalog: publicModelCatalog,
            reviewPrompt: { [weak self] in self?.reviewPrompt },
            awayStart: { [weak self] route in self?.agentList.awayStart(for: route) },
            offlineQueue: { [weak self] host in
                guard let self else { return OfflineQueue(host: host.storedValue, store: InMemoryOfflineQueueStore()) { _, _ in .notSent(.rejected("")) } }
                return offlineQueue(for: host)
            },
            supportsNewChatInWorkspace: { [weak self] in self?.supportsNewChatInWorkspace($0) ?? true },
            skeletonRowCounts: skeletonRowCounts,
            usageDisplay: usageDisplay,
            planUsageSource: { [weak self] host, agent in self?.planUsageSource(host, agent) },
            detectAgents: { [weak self] id in try await self?.detectAgents(on: id) ?? [] },
            setEnabledAgents: { [weak self] agents, id in self?.setEnabledAgents(agents, for: id) },
            hostConsent: hostConsent,
            agentHostServices: agentHostServices)
        rebuildMembers()
        agentList.selectHost = { [weak self] host in self?.select(host) }
        agentList.enterDemo = { [weak self] in self?.enterDemo() }
        agentList.currentHostDidChange = { [weak self] host in self?.currentHostStore.save(host) }
    }

    /// 成員建立畫面 model 時向清單問事情的入口(#564)。
    private var memberEnvironment: HostMemberEnvironment!

    /// 跨主機的畫面 model 工廠(#564);作用在單一主機的畫面 model 向那台主機的成員要(`HostMember+Screens.swift`)。
    public var screens: HostScreens { HostScreens(hosts: self) }

    /// Demo 主機在同意紀錄裡的主機 id。
    static let demoID = "demo"

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

    /// 方案用量的來源：Demo 主機是本機假資料(不耗 token 與傳輸);SSH 主機經主機通道;HTTPS 主機經主機服務(0.12.0 起)。
    func planUsageSource(_ host: HostSelection, _ agent: AgentID) -> PlanUsageSource? {
        let channel: any HostChannel
        let cost: PlanUsageQueryCost
        let hostID: String
        var files: HostFiles?
        switch host {
        case .demo:
            (channel, cost, hostID) = (demoChannel, .free, Self.demoID)
        case .host(let id):
            guard let configuration = hosts.first(where: { $0.id == id }) else { return nil }
            if usesHostService(configuration) {
                // HTTPS 主機經主機服務讀(0.12.0 起,#392);還沒配對或不是真的主機服務連線(UI 測試)沒有來源。
                guard AgentHostCapabilities.resolve(agent, over: .https).planUsage, !unpairedHostIDs.contains(id), !configuration.needsReconfirmation,
                    let connection = httpsAdapter.capabilities(for: configuration).hostServiceConnection.value
                else { return nil }
                return .hostService(
                    connection, agent: agent, hostID: id.uuidString, hostName: configuration.name, consent: hostConsent)
            }
            let member = member(for: host)
            (channel, cost, hostID, files) = (member.channel, .transfer, id.uuidString, member.hostFiles)
        }
        return agentHostServices.planUsage(
            for: agent,
            ssh: AgentHostServices.SSHContext(
                channel: channel, files: files, cost: cost, hostID: hostID, consent: host == .demo ? demoConsent : hostConsent))
    }

    /// 「⋯」選單要不要有登入 Shell 與檔案：有任何一台支援就有(挑選鈕能選;HTTPS 主機沒有，ADR-0010)。
    public var anyHostSupportsShell: Bool { !hostOptions { $0.supportsLoginShell }.isEmpty }

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
        let usesHostService = configuration.map(usesHostService(_:)) ?? false
        let status: HostOverview.Status
        if configuration == nil {
            status = .demo
        } else if configuration?.needsReconfirmation == true {
            status = .needsReconfirmation
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
        let pairedHostService = usesHostService && status != .needsPairing && status != .needsReconfirmation
        let hasUsageSource: Bool = switch status {
        case .demo, .needsPairing, .needsReconfirmation, .herdrTooOld: false
        case .connecting, .online, .readOnly, .offline: true
        }
        return HostOverview(
            host: selected, name: name(of: selected), icon: icon(of: selected), status: status, connection: method,
            herdrVersion: herdrVersion, address: configuration.flatMap { usesHostService ? adapter(for: $0).addressDescription(of: $0) : nil },
            showsUsage: hasUsageSource, showsHostService: pairedHostService,
            showsLoginShell: (configuration?.supportsLoginShell ?? true) && status != .needsPairing && status != .needsReconfirmation,
            canShare: configuration != nil, hasHostSettings: configuration != nil && status != .needsPairing && status != .needsReconfirmation,
            isSaved: configuration != nil)
    }

    /// herdr 低於最低支援版本(`HerdrVersion.minimumSupported`);看不懂的版本字串不算太舊。
    static func isTooOld(herdr version: String) -> Bool {
        guard let parsed = HerdrVersion(version) else { return false }
        return parsed < .minimumSupported
    }

    /// 讀選取中 HTTPS 主機的唯讀狀態與主機服務版本(主機 tab 出現時);連不上的略過。
    public func refreshOverviewFacts() async {
        // 主機 tab 出現時(列表多半已讀到快照),補上還沒設定過的主機的 Agent 設定(#477)。
        for host in hosts where host.enabledAgents == nil { await initializeAgentSettings(for: host.id, isNewHost: false) }
        guard let host = selectedHost, usesHostService(host), !unpairedHostIDs.contains(host.id), !host.needsReconfirmation,
            let connection = hostStatusConnection(for: host.id)
        else { return }
        if let readOnly = try? await connection.isReadOnlyDevice() {
            if readOnly { readOnlyHostIDs.insert(host.id) } else { readOnlyHostIDs.remove(host.id) }
        }
        if let version = try? await connection.hostServiceVersion() { hostServiceVersions[host.id] = version }
    }

    /// 沒有任何主機可看(沒有已存主機、也還沒進入範例主機):檔案與主機 tab 顯示空狀態。
    public var hasNoHostToShow: Bool { hosts.isEmpty && !demoEntered }

    /// 這台主機能不能在既有 Workspace 新增聊天(Workspace 標題選單的「在此新增聊天」)。
    /// 也是新增聊天能不能選既有 Workspace 的條件。HTTPS 主機要主機服務 0.15.0 起(`tab.create`);
    /// 已知版本不足時不提供,還不知道版本(還沒連上)時先提供,送出時版本不足會說明要更新主機服務。
    public func supportsNewChatInWorkspace(_ host: HostSelection) -> Bool {
        guard usesHostService(host), case .host(let id) = host, let installed = hostServiceVersions[id] else { return true }
        return HostServiceFeature.tabCreate.isAvailable(onHostServiceVersion: installed)
    }

    /// 已啟用的範例主機(#394)加上符合條件的已存主機(主機挑選鈕與方案用量的主機選單)。
    func hostOptions(_ isIncluded: (HostConfiguration) -> Bool) -> [HostOption] {
        (demoEntered ? [HostOption(id: .demo, name: name(of: .demo))] : [])
            + hosts.filter(isIncluded).map {
                HostOption(id: .host($0.id), name: $0.name, icon: icon(for: $0.id), needsReconfirmation: $0.needsReconfirmation)
            }
    }

    /// 新對話開始後：重讀列表，回傳那台主機上新 workspace 的 root pane 的聊天(行為規格 F3.2 第 5 步),由呼叫端交給導覽 model 開啟。
    public func startedChat(_ workspace: CreatedWorkspace, on host: HostSelection) async -> ChatRoute {
        await agentList.load()
        return ChatRoute(host: host, paneID: workspace.rootPaneID)
    }

    /// 某台主機的對話快取(key 加上主機身分)。
    public func conversationCache(for selection: HostSelection) -> any ConversationCache {
        HostScopedConversationCache(base: conversationCache, scope: selection.storedValue)
    }

    /// 背景預讀(#663):連上主機後把列表前幾個聊天讀進快取。行動網路不預讀、前景正在看的主機不預讀。
    @ObservationIgnored private var conversationPrefetcher: ConversationPrefetcher?

    /// 把這些聊天的快取讀進記憶體層(Agent 列表顯示時呼叫),打開時同步還原。
    /// `readsTranscripts`(列表在前景時):再把還沒有新快取的聊天從主機讀進來(`ConversationPrefetcher`,數量與網路有上限)。
    public func prefetchConversations(_ routes: [ChatRoute], readsTranscripts: Bool = false) async {
        for route in routes where !Task.isCancelled {
            _ = await conversationCache(for: route.host).load(chatKey: route.paneID)
        }
        guard readsTranscripts, !Task.isCancelled else { return }
        let prefetcher = conversationPrefetcher ?? ConversationPrefetcher(
            isCellular: { [weak self] in self?.trafficMeter?.currentNetwork == .cellular },
            isBlocked: { [weak self] route in self?.agentList.visibleChats.contains { $0.host == route.host } ?? true },
            read: { [weak self] candidate in await self?.prefetchTranscript(candidate) ?? false })
        conversationPrefetcher = prefetcher
        let candidates = routes.compactMap { route -> ConversationPrefetcher.Candidate? in
            guard let agent = members[route.host]?.list.updates.snapshot?.agents.first(where: { $0.paneID == route.paneID }),
                  let target = agent.transcriptTarget else { return nil }
            return ConversationPrefetcher.Candidate(route: route, target: target, signature: "\(target.sessionKey)|\(agent.status)")
        }
        await prefetcher.prefetch(candidates)
    }

    private func prefetchTranscript(_ candidate: ConversationPrefetcher.Candidate) async -> Bool {
        guard let member = members[candidate.route.host] else { return false }
        return await ConversationPrefetcher.read(
            candidate, reader: member.transcripts, cache: conversationCache(for: candidate.route.host))
    }

    public var rows: [HostRow] {
        hosts.map { host in
            let update = hostServiceUpdate(for: host.id)
            let subtitle = adapter(for: host).addressDescription(of: host)
            return HostRow(
                id: host.id, title: host.name, subtitle: subtitle, session: host.ssh?.herdr.session,
                isSelected: selection == .host(host.id), icon: icon(for: host.id), needsPairing: unpairedHostIDs.contains(host.id), needsReconfirmation: host.needsReconfirmation,
                hostServiceVersion: hostServiceVersions[host.id], hostServiceUpdate: update,
                hostServiceUpdateCommands: update.flatMap { _ in hostServiceVersions[host.id].map(HostServiceUpdates.commands(installed:)) })
        }
    }

    /// 讀每台已配對 HTTPS 主機的主機服務版本(主機清單出現時;已連線的主機不多花一個請求)與最新版本。連不上的略過;
    /// 沒有已配對的 HTTPS 主機時不查最新版本。最新版本這次取不到時沿用上次取到的。
    public func checkHostServiceVersions() async {
        let targets = hosts.compactMap { host -> (UUID, any HostConnection)? in
            guard !unpairedHostIDs.contains(host.id), !host.needsReconfirmation, let connection = httpsAdapter.connection(for: host) else { return nil }
            return (host.id, connection)
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
        guard let host = hosts.first(where: { $0.id == id }), !unpairedHostIDs.contains(id), !host.needsReconfirmation else { return nil }
        return httpsAdapter.connection(for: host)
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

    /// 主機清單讀過了(畫面在這之前顯示系統進度指示,不顯示「沒有主機」的空狀態,#590)。
    public private(set) var isLoaded = false

    /// 從儲存讀主機清單，選回上次選取的主機。
    public func load() {
        finishLoad(Result { try sortedHosts() })
    }

    /// 冷啟動用(#590):Keychain 在背景讀,第一個 frame 不等它;讀完才套用並設 `isLoaded`。
    public func loadInBackground() async {
        guard !isLoaded else { return }
        let result: Result<[HostConfiguration], any Error>
        do {
            result = .success(try await store.loadHostsInBackground().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        } catch {
            result = .failure(error)
        }
        guard !isLoaded else { return }
        finishLoad(result)
    }

    private func finishLoad(_ result: Result<[HostConfiguration], any Error>) {
        switch result {
        case .success(let loaded):
            hosts = loaded
            refreshPairing()
            loadError = nil
        case .failure(let error):
            loadError = DisplayedError(
                String(localized: "Couldn’t read saved hosts on this device. \(error.localizedDescription)"), error: error)
        }
        select(validSelection(selectionStore.load()))
        // 存的目前主機已不在列表上(刪除或同步移除)就維持所有主機。
        if let stored = currentHostStore.load(), agentList.hostLabel(of: stored) != nil { agentList.currentHost = stored }
        // 舊版 app 存的主機還沒有 Agent 設定:連得上時補初始化(#477)。
        for host in hosts where host.enabledAgents == nil {
            Task { await initializeAgentSettings(for: host.id, isNewHost: false) }
        }
        isLoaded = true
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
        let isNewHost = !hosts.contains { $0.id == host.id }
        changeRecorder?.hostSaved(host.id)
        hosts = (try? sortedHosts()) ?? hosts
        refreshPairing()
        dropChannel(of: host.id)
        members[.host(host.id)] = nil
        select(.host(host.id))
        // 新增主機:偵測有哪些 Agent 並預先打開(#477);改設定的既有主機沒設定過才補初始化。
        Task { await initializeAgentSettingsWhenReachable(for: host.id, isNewHost: isNewHost) }
    }

    /// HTTPS 主機要等列表讀到快照才偵測得到:每秒再試,最多 10 次;其他主機只試一次。
    package func initializeAgentSettingsWhenReachable(for id: UUID, isNewHost: Bool) async {
        let attempts = hosts.first { $0.id == id }.map { adapter(for: $0).traits.agentDetection.attempts } ?? 1
        for attempt in 0..<attempts {
            if attempt > 0 { try? await sleep(.seconds(1)) }
            await initializeAgentSettings(for: id, isNewHost: isNewHost)
            if hosts.first(where: { $0.id == id })?.enabledAgents != nil { return }
        }
    }

    // MARK: - 主機的 Agent 設定(#477)

    /// 這台主機啟用的 Agent(`HostAgentSettings`):還沒設定過的主機沿用升級前的行為;範例主機全開。
    public func enabledAgents(on host: HostSelection) -> Set<AgentID> {
        switch host {
        case .demo: Set(HostAgentSettings.configurable)
        case .host(let id): HostAgentSettings.effective(hosts.first { $0.id == id }?.enabledAgents)
        }
    }

    /// 存這台主機啟用的 Agent。只存在這支裝置:不算主機的修改(不同步),也不重建連線。
    public func setEnabledAgents(_ agents: Set<AgentID>, for id: UUID) {
        guard var host = hosts.first(where: { $0.id == id }), host.enabledAgents != agents else { return }
        host.enabledAgents = agents
        guard (try? store.save(host)) != nil else { return }
        hosts = (try? sortedHosts()) ?? hosts
    }

    /// 主機上有哪些 Agent:SSH 看設定資料夾(唯讀);HTTPS 看 herdr 快照裡出現過的種類。連不上時丟出錯誤。
    func detectAgents(on id: UUID) async throws -> Set<AgentID> {
        guard let host = hosts.first(where: { $0.id == id }) else { return [] }
        let member = member(for: .host(id))
        if case .snapshot = adapter(for: host).traits.agentDetection {
            // 不為了偵測另外讀快照(會搶走列表自己的讀取):列表讀到之後才有,還沒有就稍後再試。
            guard let snapshot = member.list.snapshot else { throw HostAgentDetectionError.unavailable }
            return Set(snapshot.agents.map { AgentID(herdrName: $0.kind) })
        }
        return try await HostAgentDetector(files: HostFiles(channel: member.channel)).installedAgents()
    }

    /// 還沒設定過的主機補上 Agent 設定:新增的以偵測結果預先打開,既有的(舊版 app 存的)沿用目前顯示用量的 Agent 再加偵測結果。
    /// 偵測不到(主機離線)就不寫,維持沒設定過、下次再試;設定過的不覆蓋。
    public func initializeAgentSettings(for id: UUID, isNewHost: Bool) async {
        guard let host = hosts.first(where: { $0.id == id }), host.enabledAgents == nil,
            let detected = try? await detectAgents(on: id),
            // 偵測期間使用者可能已經手動設定過。
            hosts.first(where: { $0.id == id })?.enabledAgents == nil
        else { return }
        // HTTPS 只看得到「當下有在跑的 Agent」:一個都沒看到不代表沒裝,不寫入空集合(否則新增聊天選單會全空),
        // 維持還沒設定、沿用預設,稍後再偵測。
        if case .snapshot = adapter(for: host).traits.agentDetection, detected.intersection(HostAgentSettings.configurable).isEmpty { return }
        setEnabledAgents(isNewHost ? HostAgentSettings.initial(detected: detected) : HostAgentSettings.migrated(detected: detected), for: id)
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
        // 還沒重新確認的主機不再連線:不對它(可能是被改掉的位址)送出密碼、私鑰或權杖(#572);其餘由該連線方式的 adapter 收尾。
        if let removed, !removed.needsReconfirmation {
            adapter(for: removed).cleanUpAfterRemoval(
                HostRemoval(
                    configuration: removed, secret: secret, deviceToken: deviceToken,
                    restoresDeviceKey: hostConsent.isGranted(AuthorizedKeyInstaller.feature.id, host: id.uuidString)))
        }
        hostConsent.revokeAll(host: id.uuidString)
        // 刪除主機也清掉它的離線佇列(#301)。
        offlineQueues[.host(id)] = nil
        offlineQueueStore.save([], host: HostSelection.host(id).storedValue)
        hosts.removeAll { $0.id == id }
        let dropping = [sshAdapter.drop(id), httpsAdapter.drop(id)]
        members[.host(id)] = nil
        conversationPrefetcher?.forget(host: .host(id))
        preferences.removeAll(for: .host(id))
        hostIcons.setIcon(nil, for: id)
        try? FileManager.default.removeItem(at: AgentFileLoads.defaultDownloadDirectory.appending(path: id.uuidString, directoryHint: .isDirectory))
        hostServiceVersions[id] = nil
        dismissedHostServiceUpdates[id] = nil
        hostServiceUpdates.store.setDismissedVersion(nil, for: id)
        if selection == .host(id) { select(validSelection(nil)) } else { rebuildMembers() }
        await conversationCache.removeAll(chatKeyPrefix: HostScopedConversationCache.prefix(scope: HostSelection.host(id).storedValue))
        for task in dropping { await task?.value }
    }

    /// 主機的分享連結(QR code 內容)。不含任何祕密。
    public func shareLink(for id: UUID) -> URL? {
        hosts.first { $0.id == id }.map(HostShareLink.url(for:))
    }

    /// 點了推播通知(純函式,不改畫面狀態)：轉成配對主機上該 Agent 的聊天目的地;主機服務通知回傳要開編輯頁的主機。所有主機都在同一個列表，所以不改選取中主機。
    /// 不認得的配對(主機已移除)不動。
    @discardableResult
    public func open(_ route: PushRoute, pairings: any PushPairingStore) -> PushDestination? {
        if route.event == PushRoute.testEvent { return nil }
        guard let hostID = pairings.host(forKeyHash: route.keyHash), let id = UUID(uuidString: hostID),
              hosts.contains(where: { $0.id == id }) else { return nil }
        if route.event != nil { return .hostEditor(id) }
        guard let paneID = route.paneID else { return nil }
        return .chat(ChatRoute(host: .host(id), paneID: paneID))
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

    /// 引導最後一頁判斷有沒有登入用的檢查(同推播開關)。沒有推播服務就當沒登入。
    var guideSignedInCheck: @MainActor () async -> Bool {
        { [pushService] in
            guard let pushService else { return false }
            return await pushService.isSignedIn()
        }
    }

    /// 連線測試、配對與撤銷等「還沒有連線」的流量依主機 id 記進數據用量(#353);沒有計量時不記。
    var trafficProvider: (UUID) -> TrafficRecording {
        { [trafficMeter] id in trafficMeter?.recorder(for: id.uuidString) ?? { _, _ in } }
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
        let demoChannel = demoChannel
        let disconnectors = sshAdapter.disconnectors() + httpsAdapter.disconnectors() + [{ await demoChannel.disconnect() }]
        let channelCount = sshAdapter.liveChannels.count
        // 診斷(#133):實機斷線時分辨是不是網路切換丟掉了連線。
        diagnostics.error("Network path changed (\(previous) → \(signature)): dropping \(channelCount) host connection(s)")
        diagnosticEvents.record(.networkChanged(droppedConnections: channelCount, detail: "\(previous) → \(signature)"))
        let agentList = agentList
        return Task {
            for disconnect in disconnectors { await disconnect() }
            agentList.retryNow()
        }
    }

    public func sceneDidEnterBackground(at date: Date) {
        backgroundSince = date
    }

    /// 回到前景(#550):背景超過保留時間(`BackgroundRetention`)就當連線已被 iOS 關掉,直接丟棄重撥——
    /// 不跑喚醒探測(等探測逾時比重撥慢);列表沿用最後的快照,立刻對每台主機預先撥號,不等第一個畫面請求。
    /// 沒超過就沿用現有連線。
    public func sceneDidBecomeActive(at date: Date) async {
        guard let since = backgroundSince else { return }
        backgroundSince = nil
        let backgroundSeconds = date.timeIntervalSince(since)
        let decision = ForegroundReconnectPolicy.decision(backgroundSeconds: backgroundSeconds)
        // 診斷(#133、#550):實機量測回前景的重連走哪條路。
        diagnostics.error(ForegroundReconnectPolicy.logLine(backgroundSeconds: backgroundSeconds, decision: decision))
        diagnosticEvents.record(.foregroundDecision(backgroundSeconds: Int(backgroundSeconds), redial: decision == .redial))
        guard decision == .redial else { return }
        let disconnectors = sshAdapter.disconnectors() + httpsAdapter.disconnectors()
        let prewarmers = sshAdapter.prewarmers() + httpsAdapter.prewarmers()
        for disconnect in disconnectors { await disconnect() }
        agentList.reconnectAfterForeground()
        await withTaskGroup(of: Void.self) { group in
            for prewarm in prewarmers { group.addTask { await prewarm() } }
        }
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
            adapter(for: host).traits.usesHostService && (try? tokens.deviceToken(for: host.id)) == nil
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
        guard !configuration.needsReconfirmation else { return .unsupported }
        guard members[host]?.push.isAvailable == true else { return .unsupported }
        // 版本還不知道(還沒連上)時先當可開：開啟時主機服務太舊會說明要更新。
        guard usesHostService(configuration), let installed = hostServiceVersions[id],
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
        return hosts.first { $0.id == id }.map(usesHostService(_:)) ?? false
    }

    private func usesHostService(_ configuration: HostConfiguration) -> Bool {
        adapter(for: configuration).traits.usesHostService
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

    private func needsReconfirmation(_ host: HostSelection) -> Bool {
        guard case .host(let id) = host else { return false }
        return hosts.first { $0.id == id }?.needsReconfirmation ?? false
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
                    notes: member.youShouldKnow, needsReconfirmation: needsReconfirmation(host))
            }
        }
        agentList.isAwaitingFirstHost = hosts.isEmpty && !demoEntered
        agentList.update(sources: sources, selected: selection)
    }

    /// 某台主機的離線佇列(#301):第一次用到時從本機讀回。補送前以新鮮的快照確認 Agent 目前的狀態。
    public func offlineQueue(for host: HostSelection) -> OfflineQueue {
        if let queue = offlineQueues[host] { return queue }
        let queue = OfflineQueue(host: host.storedValue, store: offlineQueueStore) { [weak self] text, destination in
            guard let client = self?.member(for: host).client else { return .notSent(.rejected("")) }
            return await SafeSend(client: client).send(text, to: destination)
        }
        offlineQueues[host] = queue
        return queue
    }

    /// 某台主機的成員;不在列表上時(例如剛刪除的主機還開著的畫面)暫時建一個不保留的。
    package func member(for host: HostSelection) -> HostMember {
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
                host: host, hostID: Self.demoID, capabilities: demoAdapter.companionCapabilities(channel: companion.channel),
                preferences: preferences.store(for: host), push: pushService, environment: memberEnvironment)
        }
        let configuration: HostConfiguration? = switch host {
        case .demo: nil
        case .host(let id): hosts.first { $0.id == id }
        }
        guard let configuration else {
            return HostMember(
                host: host, hostID: Self.demoID, capabilities: demoAdapter.demoHostCapabilities(),
                preferences: preferences.store(for: host), push: pushService, environment: memberEnvironment)
        }
        // 同步改了位址或 host key、使用者還沒重新確認:不開任何連線(#572)。
        let capabilities = configuration.needsReconfirmation
            ? SSHHostAdapter.blocked(configuration, consent: hostConsent)
            : adapter(for: configuration).capabilities(for: configuration)
        return HostMember(
            host: host, hostID: configuration.id.uuidString, capabilities: capabilities,
            preferences: preferences.store(for: host), push: pushService, environment: memberEnvironment)
    }

    /// 連線方式 → adapter:全 app 唯一依連線方式分派的地方。
    private func adapter(for configuration: HostConfiguration) -> any HostAdapter {
        switch configuration.connection {
        case .https: httpsAdapter
        case .tailscaleSSH, .openSSH: sshAdapter
        }
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

    private func dropChannel(of id: UUID) {
        sshAdapter.drop(id)
        httpsAdapter.drop(id)
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
        /// 主機同步改了位址或 host key(#572):使用者重新確認前不連線。
        case needsReconfirmation
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

    /// 狀態卡要不要畫骨架(#496):只有「第一次連線、還沒讀到任何內容」才畫;重連時(已有 herdr 版本)保留最後已知的內容。
    public var showsSkeleton: Bool { status == .connecting && herdrVersion == nil }
}

/// 偵測主機上的 Agent 失敗(HTTPS 主機讀不到 herdr 快照)。
enum HostAgentDetectionError: Error {
    case unavailable
}
