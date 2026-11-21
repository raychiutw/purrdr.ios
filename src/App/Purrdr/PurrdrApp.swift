import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrDemo
import PurrdrFeatures
import PurrdrSSH
import StoreKit
import SwiftUI

/// 唯一的 composition root:組裝主機儲存、主機通道、Purrdr 後台與畫面 model。
///
/// 已存的主機經真 SSH(swift-nio-ssh)連線;沒有主機時用 Demo 主機。UI 測試以 `-uiTesting` 啟動，
/// 一律只用 Demo 主機：主機存在記憶體、不碰 Keychain,任何主機的通道也都是 Demo 主機，不連網路。
@main
struct PurrdrApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var hosts: HostsModel
    private let member: MemberModel
    /// Purrdr Plus(#28)。跟會員共用同一個 `MemberSession`(同一組權杖)。
    private let plus: SubscriptionModel
    private let settings: SettingsModel
    /// 主機同步(#30):跟會員、Purrdr Plus 共用同一個 `MemberSession`。
    private let hostSync: HostSyncModel
    /// 第一次開啟的歡迎頁(#34)。
    private let welcome: WelcomeModel
    /// 配對碼掃描(#250):UI 測試以旗標模擬，不開真相機。
    private let pairingCodeScanSource: PairingCodeScanSource
    /// App 鎖(#284):所有視窗共用一份鎖定狀態。
    private let appLock: AppLock
    /// 所有場景合併的生命週期(App 鎖依它判斷離開多久)。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let uiTesting = arguments.contains("-uiTesting")
        // Tailscale SSH check mode 的提示：所有主機通道共用。
        let tailscaleCheck = TailscaleCheckModel()
        let demo = DemoHost(scenario: Self.demoScenario(arguments), tailscaleCheck: tailscaleCheck.observer)
        // 對話快取。目前存在記憶體(app 執行期間);持久化(SwiftData)在之後的票。
        let cache = InMemoryConversationCache()
        // UI 測試每次啟動都從空白的釘選、靜音與主機圖示開始，不讀寫這台模擬器的 UserDefaults。
        // 釘選、靜音依主機分開(#39);舊版沒有主機身分的資料在第一次啟動時丟棄。
        let preferences: any HostChatPreferencesStore = uiTesting
            ? InMemoryHostChatPreferencesStore() : UserDefaultsHostChatPreferencesStore()
        let hostIcons: any HostIconStore = uiTesting ? InMemoryHostIconStore() : UserDefaultsHostIconStore()
        let session = Self.makeMemberSession(uiTesting: uiTesting, arguments: arguments)
        member = MemberModel(
            session: session,
            google: GoogleSignIn(configuration: GoogleSignIn.Configuration(clientID: BackendConfiguration.googleClientID))
        )
        // StoreKit:在 Xcode 執行時，scheme 指定的 StoreKit 設定檔(src/App/Purrdr.storekit)提供商品，不連 App Store。
        // UI 測試用內容相同的替身(不連網路;命令列 xcodebuild test 不套用 StoreKit 設定檔)。
        let store: any PlusStore = uiTesting ? UITestingPlusStore() : StoreKitPlusStore()
        let plus = SubscriptionModel(session: session, store: store)
        self.plus = plus
        // 推播(#29):UI 測試不請求權限、不註冊 APNs、配對只在記憶體。
        let push = PushService(
            session: session,
            platform: uiTesting ? UITestingPushPlatform(isAuthorized: Self.uiTestingMemberBackend(arguments) != nil) : PushAppDelegate.platform,
            store: uiTesting ? InMemoryPushPairingStore() : UserDefaultsPushPairingStore(),
            loadDevice: Self.pushDevice(uiTesting: uiTesting),
            configuration: PushConfiguration(
                endpoint: PushSettings.endpoint, environment: PushSettings.environment, pluginSource: PushSettings.pluginSource)
        ) {
            await plus.refresh()
            return plus.isPlusActive
        }
        let hosts: HostsModel
        if uiTesting {
            // 祕密只放記憶體;裝置金鑰是軟體金鑰(模擬器沒有 Secure Enclave)。
            let credentials = HostCredentials(secrets: EphemeralHostSecretStore(), deviceKey: EphemeralDeviceKey())
            hosts = HostsModel(
                store: EphemeralHostStore(hosts: Self.seededHosts(arguments)), demoChannel: demo, demoFiles: DemoHostFileFetcher(),
                // 示範主機在 UI 測試要明確開啟(`-demoCompanions`),其他測試的列表才不會多出它們的列。
                demoCompanions: arguments.contains("-demoCompanions") ? Self.demoCompanions(demo) : [],
                conversationCache: cache, preferences: preferences, hostIcons: hostIcons,
                selectionStore: InMemoryHostSelectionStore(arguments.contains("-selectDemo") ? .demo : nil),
                hostConsent: InMemoryHostWriteConsentStore(), credentials: credentials,
                // HTTPS 主機：配對不連網路，連線是 Demo 主機。`-demoOutdatedHostService`:主機服務是舊版(更新提示,#198)。
                hostService: .uiTesting(
                    channel: demo,
                    hostServiceVersion: arguments.contains("-demoOutdatedHostService") ? "0.0.1" : HostServiceUpdates.latestKnownVersion,
                    pairedHosts: arguments.contains("-seedPairedHTTPSHost") ? [Self.pairedHTTPSHost.id] : [],
                    readOnlyHosts: arguments.contains("-seedReadOnlyHTTPSHost") ? [Self.readOnlyHTTPSHost.id] : []),
                push: push, tailscaleCheck: tailscaleCheck,
                // UI 測試的圖片副本放暫存資料夾，不留在 app 的資料裡。
                attachmentStore: FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "Attachments")),
                listMode: Self.uiTestingListMode(arguments),
                // `-seedUnreachableHost` 的主機一律連不上(多主機情境：一台連不上不影響其他台);`-seedSlowHost` 的主機連線卡住(#221)。
                makeChannel: { endpoint, _, _ in
                    if endpoint.host == Self.unreachableHost.ssh?.endpoint.host { return DemoUnreachableChannel() as any HostChannel }
                    if endpoint.host == Self.slowHost.ssh?.endpoint.host { return DemoUnreachableChannel(hangs: true) as any HostChannel }
                    return demo
                })
        } else {
            // 公鑰註解只帶裝置種類(「iPhone」「iPad」),不帶使用者取的裝置名稱。
            let credentials = HostCredentials(
                secrets: KeychainHostSecretStore(), deviceKey: SecureEnclaveDeviceKey(comment: "purrdr@\(UIDevice.current.model)"))
            // 主機寫入的同意(Claude 方案用量等):真主機存在 UserDefaults;Demo 主機的只在記憶體(HostsModel 預設)。
            hosts = HostsModel(
                store: KeychainHostStore(), demoChannel: demo, demoFiles: DemoHostFileFetcher(), demoCompanions: Self.demoCompanions(demo),
                conversationCache: cache, preferences: preferences, hostIcons: hostIcons,
                selectionStore: UserDefaultsHostSelectionStore(), planUsageSelection: UserDefaultsPlanUsageSelectionStore(),
                hostPicker: UserDefaultsHostPickerStore(),
                hostConsent: UserDefaultsHostWriteConsentStore(), credentials: credentials,
                // 裝置名稱只帶裝置種類(同公鑰註解),顯示在主機的裝置列表。
                hostService: .system(
                    deviceName: UIDevice.current.model,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
                hostServiceUpdates: HostServiceUpdates(store: UserDefaultsHostServiceUpdateStore()),
                push: push, tailscaleCheck: tailscaleCheck,
                listMode: UserDefaultsAgentListModeStore(),
                // 離線佇列存在本機，App 重開仍在(#301)。
                offlineQueues: UserDefaultsOfflineQueueStore()
            ) { endpoint, pin, credential in
                SSHHostChannel(
                    endpoint: endpoint, hostKeyPin: pin, credential: credential, tailscaleCheck: tailscaleCheck.observer,
                    // 連線診斷(#133):Console 篩 subsystem com.raychiu.purrdr、category ssh。
                    diagnostics: SSHConnectionLog.system(host: endpoint.host))
            }
        }
        // `-demoNoNetwork`:裝置一直沒有網路(#221;Demo 主機同時斷網)。
        if uiTesting, arguments.contains("-demoNoNetwork") { hosts.simulatesNoNetwork = true }
        hosts.haptics = SystemHaptics()
        hosts.reviewPrompt = Self.makeReviewPrompt(uiTesting: uiTesting)
        // 送出可撤回(#300):UI 測試預設關閉(其他測試送出不等倒數);`-uiTestingUndoSend` 開 10 秒倒數(來得及點撤回)。
        if uiTesting { hosts.undoSendSeconds = { arguments.contains("-uiTestingUndoSend") ? 10 : 0 } }
        hosts.load()
        _hosts = State(initialValue: hosts)
        // 主機同步(#30):UI 測試不讀寫這台模擬器的 UserDefaults(後台是 backend.invalid,開啟時一律提示需要 Purrdr Plus)。
        hostSync = HostSyncModel(
            session: session, plus: plus, hosts: hosts, store: uiTesting ? InMemoryHostSyncStore() : UserDefaultsHostSyncStore())
        settings = Self.makeSettings(hosts: hosts)
        // UI 測試預設當作看過(不擋住其他測試);`-showWelcome` 測歡迎頁本身。
        welcome = WelcomeModel(store: uiTesting
            ? InMemoryWelcomeStore(hasSeen: !arguments.contains("-showWelcome")) : UserDefaultsWelcomeStore())
        pairingCodeScanSource = Self.pairingCodeScanSource(arguments)
        appLock = Self.makeAppLock(uiTesting: uiTesting, arguments: arguments)
    }

    /// App 鎖：設定存在本機偏好(預設關閉、不同步)。UI 測試用替身與另一個 UserDefaults suite,
    /// `-uiTestingAppLock` 以已開啟啟動，`-uiTestingNoPasscode` 模擬沒有裝置密碼。
    private static func makeAppLock(uiTesting: Bool, arguments: [String]) -> AppLock {
        guard uiTesting else { return AppLock(authenticator: SystemDeviceOwnerAuthenticator(), defaults: .standard) }
        let suiteName = "uiTesting.appLock"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(arguments.contains("-uiTestingAppLock"), forKey: AppLock.enabledKey)
        return AppLock(
            authenticator: UITestingDeviceOwnerAuthenticator(hasPasscode: !arguments.contains("-uiTestingNoPasscode")), defaults: defaults)
    }

    /// `-uiTestingPairingScan`:掃描畫面一開就像掃到配對 QR code;`-uiTestingCameraDenied`:沒有相機權限。
    private static func pairingCodeScanSource(_ arguments: [String]) -> PairingCodeScanSource {
        if arguments.contains("-uiTestingCameraDenied") { return .simulatedCameraDenied }
        guard arguments.contains("-uiTestingPairingScan") else { return .camera }
        return .simulated(payload: "purrdr://pair?address=https%3A%2F%2Fstudio.tail1234.ts.net%3A8443&code=K7QM-2XPA")
    }

    /// UI 測試的列表檢視(Spaces／Agents)存放處：預設只在記憶體，每次啟動都從 Agents 開始(同正式 app 沒存過時;
    /// #275 起 Spaces 檢視是 Tab 列、沒有 Agent 列，測 Spaces 的測試自己切過去)。
    /// `-rememberListMode` 改存 UserDefaults(另一個 key,不碰正式的 `agentListMode`),測沒有記錄時的預設與「重新啟動後記住」(#66);
    /// `-resetListMode` 先清掉上次留下的值。
    private static func uiTestingListMode(_ arguments: [String]) -> any AgentListModeStore {
        guard arguments.contains("-rememberListMode") else { return InMemoryAgentListModeStore(.agents) }
        let key = "uiTesting.agentListMode"
        if arguments.contains("-resetListMode") { UserDefaults.standard.removeObject(forKey: key) }
        return UserDefaultsAgentListModeStore(key: key)
    }

    /// 成功送出幾次 prompt 後請求評分(#34)。UI 測試只在記憶體計數、不叫出系統的評分對話框(會擋住後面的操作)。
    private static func makeReviewPrompt(uiTesting: Bool) -> ReviewPrompt {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard !uiTesting else { return ReviewPrompt(store: InMemoryReviewPromptStore(), appVersion: version) {} }
        return ReviewPrompt(store: UserDefaultsReviewPromptStore(), appVersion: version) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
            AppStore.requestReview(in: scene)
        }
    }

    /// 設定頁。偏好存在 `UserDefaults.standard`(輸入列的 `@AppStorage` 讀同一個 key)。
    private static func makeSettings(hosts: HostsModel) -> SettingsModel {
        let info = Bundle.main.infoDictionary ?? [:]
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let app = AppInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            system: "\(UIDevice.current.systemName) \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            // 只用裝置種類(model),不用 UIDevice.name:裝置名稱常含使用者本名。
            device: UIDevice.current.model
        )
        return SettingsModel(
            // 選取中的主機(沒有已存主機時是 Demo 主機);主機數只算已存的主機，不含 Demo。
            app: app, client: { hosts.herdrClient }, hostCount: { hosts.hosts.count }, defaults: .standard,
            platform: SystemPlatformServices(), links: AppStoreConfiguration.settingsLinks
        )
    }

    /// UI 測試情境 `-seedHost`:已存一台主機(通道仍是 Demo 主機)，測主機清單的管理動作。
    private static let seededHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000001")!, name: "Studio Mac",
        endpoint: SSHEndpoint(host: "studio-mac", username: "demo"), operatingSystem: .macOS)

    /// UI 測試情境 `-seedUnreachableHost`:再存一台連不上的主機(多主機合併列表，#39)。
    private static let unreachableHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000002")!, name: "Build Box",
        endpoint: SSHEndpoint(host: "build-box.invalid", username: "demo"), operatingSystem: .linux)

    /// Demo 的示範主機(#34,App Review 也看得到):「Studio Mac」(內容同 Demo 主機)與一律連不上的「Build Box」,
    /// 演出多主機合併列表與連線中斷。只在 Demo 主機出現在列表時出現，不是已存主機。
    private static func demoCompanions(_ demo: DemoHost) -> [DemoCompanionHost] {
        [
            DemoCompanionHost(id: UUID(uuidString: "DE300000-0000-4000-8000-000000000001")!, name: "Studio Mac", icon: .macMini, channel: demo),
            DemoCompanionHost(
                id: UUID(uuidString: "DE300000-0000-4000-8000-000000000002")!, name: "Build Box", icon: .rack,
                channel: DemoUnreachableChannel()),
        ]
    }

    /// UI 測試情境 `-seedSlowHost`:再存一台連線卡住的主機(列表的「連線中」與「仍在連線」,#221)。
    private static let slowHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000004")!, name: "Slow Box",
        endpoint: SSHEndpoint(host: "slow-box.invalid", username: "demo"), operatingSystem: .linux)

    /// UI 測試情境 `-seedUnpairedHTTPSHost`:主機同步帶來、這支裝置還沒配對的 HTTPS 主機(#63)。
    private static let unpairedHTTPSHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000003")!, name: "Studio HTTPS",
        hostService: HostServiceAddress("studio.tail1234.ts.net")!)

    /// UI 測試情境 `-seedReadOnlyHTTPSHost`:這支裝置已用唯讀權杖配對好的 HTTPS 主機(主機頁的主機服務區塊,#290)。
    private static let readOnlyHTTPSHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000005")!, name: "Studio",
        hostService: HostServiceAddress("studio.tail1234.ts.net")!)

    /// UI 測試情境 `-seedPairedHTTPSHost`:這支裝置已配對好的 HTTPS 主機(主機頁的已配對裝置區塊,#291)。
    private static let pairedHTTPSHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000006")!, name: "Studio",
        hostService: HostServiceAddress("studio.tail1234.ts.net")!)

    private static func seededHosts(_ arguments: [String]) -> [HostConfiguration] {
        (arguments.contains("-seedHost") ? [seededHost] : []) + (arguments.contains("-seedUnreachableHost") ? [unreachableHost] : [])
            + (arguments.contains("-seedUnpairedHTTPSHost") ? [unpairedHTTPSHost] : [])
            + (arguments.contains("-seedReadOnlyHTTPSHost") ? [readOnlyHTTPSHost] : [])
            + (arguments.contains("-seedPairedHTTPSHost") ? [pairedHTTPSHost] : [])
            + (arguments.contains("-seedSlowHost") ? [slowHost] : [])
    }

    /// UI 測試情境(啟動旗標):桌機正在操作 Demo 的 Pane;Tailscale SSH check mode(一直等、或 3 秒後驗證完成);
    /// 對話紀錄一直讀不完(停在對話載入中，到讀取期限 20 秒為止);開啟 ledger 的對話 8 秒後、或每次送出 prompt 後 agent 一次寫出大量輸出(#130);
    /// 啟動 12 秒後斷網(立刻失敗，或每個指令等 10 秒才失敗,#219);啟動就沒有網路(每個指令等 10 秒才失敗,#221)。
    /// 情境只能選一個：旗標互斥，同時帶多個時只採用下面順序中的第一個。
    private static func demoScenario(_ arguments: [String]) -> DemoHost.Scenario {
        if arguments.contains("-demoPaneInUse") { return .paneInUse }
        if arguments.contains("-demoTailscaleCheck") { return .tailscaleCheck(completesAfter: nil) }
        if arguments.contains("-demoTailscaleCheckCompletes") { return .tailscaleCheck(completesAfter: .seconds(3)) }
        if arguments.contains("-demoTranscriptPending") { return .transcriptPending }
        if arguments.contains("-demoLargeOutput") { return .largeOutput(after: .seconds(8)) }
        if arguments.contains("-demoLargeOutputOnPrompt") { return .largeOutputOnPrompt }
        if arguments.contains("-demoWorkingAfterPrompt") { return .workingAfterPrompt(for: .seconds(15)) }
        if arguments.contains("-demoAgentFiles") { return .agentFiles }
        if arguments.contains("-demoGoesOffline") { return .goesOffline(after: .seconds(12), hangs: false) }
        if arguments.contains("-demoGoesOfflineHanging") { return .goesOffline(after: .seconds(12), hangs: true) }
        if arguments.contains("-demoNoNetwork") { return .goesOffline(after: .zero, hangs: true) }
        return .standard
    }

    /// UI 測試模式：權杖只放記憶體(不碰 Keychain)、後台指向不存在的位址(不連網路)。
    /// `-uiTestingMember`／`-uiTestingPlusMember`:改用假後台，以已登入的會員啟動(帳號頁的開通流程,#246)。
    private static func makeMemberSession(uiTesting: Bool, arguments: [String]) -> MemberSession {
        if uiTesting, let backend = uiTestingMemberBackend(arguments) {
            return MemberSession(transport: backend, tokenStore: InMemoryTokenStore(refreshToken: UITestingBackendTransport.refreshToken))
        }
        let baseURL = uiTesting ? URL(string: "https://backend.invalid")! : BackendConfiguration.baseURL
        let tokenStore: any TokenStore = uiTesting ? InMemoryTokenStore() : KeychainTokenStore()
        return MemberSession(transport: URLSessionBackendTransport(baseURL: baseURL), tokenStore: tokenStore)
    }

    /// 這支裝置(#266):推播 id 存 Keychain(讀不到時稍後再試),名稱預設是系統的裝置名稱(使用者可在帳號頁改)。
    /// UI 測試用固定的 id(與假後台一致),不碰 Keychain。
    private static func pushDevice(uiTesting: Bool) -> @MainActor () throws -> PushDeviceIdentity {
        {
            let model: PushDeviceModel = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
            guard !uiTesting else {
                return PushDeviceIdentity(id: PushDeviceID(rawValue: UITestingBackendTransport.thisDeviceID)!, name: model.rawValue, model: model)
            }
            let name = PushDeviceIdentity.validName(UIDevice.current.name) ?? model.rawValue
            return PushDeviceIdentity(id: try KeychainPushDeviceID().load(), name: name, model: model)
        }
    }

    private static func uiTestingMemberBackend(_ arguments: [String]) -> UITestingBackendTransport? {
        if arguments.contains("-uiTestingPlusMember") { return UITestingBackendTransport(isPlusActive: true) }
        if arguments.contains("-uiTestingMember") { return UITestingBackendTransport(isPlusActive: false) }
        return nil
    }

    var body: some Scene {
        // 主視窗(三欄)。iPad 可以開好幾個，每個視窗有自己的導覽狀態;主機與 Agent 列表共用。
        WindowGroup(id: PurrdrCommands.mainWindowID) {
            TopNavigationView(
                hosts: hosts, member: member, settings: settings, plus: plus, hostSync: hostSync, notifications: PushAppDelegate.router,
                welcome: welcome, appLock: appLock)
            .appAppearance()
            .appLockCover(appLock)
            .environment(\.pairingCodeScanSource, pairingCodeScanSource)
        }
        .commands { PurrdrCommands() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            appLock.scenePhaseChanged(to: AppLockPhase(phase), at: .now)
        }
        // 「在新視窗開啟」的 Agent 對話或 Pane 終端機(#31)。
        WindowGroup(for: PaneWindow.self) { $window in
            if let window {
                PaneWindowView(window: window, hosts: hosts)
                    .appAppearance()
                    .appLockCover(appLock)
            }
        }
    }
}

