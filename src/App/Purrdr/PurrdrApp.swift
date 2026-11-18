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
        let session = Self.makeMemberSession(uiTesting: uiTesting)
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
            platform: uiTesting ? UITestingPushPlatform() : PushAppDelegate.platform,
            store: uiTesting ? InMemoryPushPairingStore() : UserDefaultsPushPairingStore(),
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
                store: EphemeralHostStore(hosts: Self.seededHosts(arguments)), demoChannel: demo,
                // 示範主機在 UI 測試要明確開啟(`-demoCompanions`),其他測試的列表才不會多出它們的列。
                demoCompanions: arguments.contains("-demoCompanions") ? Self.demoCompanions(demo) : [],
                conversationCache: cache, preferences: preferences, hostIcons: hostIcons,
                selectionStore: InMemoryHostSelectionStore(arguments.contains("-selectDemo") ? .demo : nil),
                hostConsent: InMemoryHostWriteConsentStore(), credentials: credentials,
                // HTTPS 主機：配對不連網路，連線是 Demo 主機。`-demoOutdatedHostService`:主機服務是舊版(更新提示,#198)。
                hostService: .uiTesting(
                    channel: demo,
                    hostServiceVersion: arguments.contains("-demoOutdatedHostService") ? "0.0.1" : HostServiceUpdates.latestKnownVersion),
                push: push, tailscaleCheck: tailscaleCheck,
                // UI 測試的圖片副本放暫存資料夾，不留在 app 的資料裡。
                attachmentStore: FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "Attachments")),
                // 滑動提示每次啟動都顯示(只在記憶體)。
                swipeHint: InMemorySwipeHintStore(),
                listMode: Self.uiTestingListMode(arguments),
                // `-seedUnreachableHost` 的主機一律連不上(多主機情境：一台連不上不影響其他台)。
                makeChannel: { endpoint, _, _ in endpoint.host == Self.unreachableHost.ssh?.endpoint.host ? DemoUnreachableChannel() as any HostChannel : demo })
        } else {
            // 公鑰註解只帶裝置種類(「iPhone」「iPad」),不帶使用者取的裝置名稱。
            let credentials = HostCredentials(
                secrets: KeychainHostSecretStore(), deviceKey: SecureEnclaveDeviceKey(comment: "purrdr@\(UIDevice.current.model)"))
            // 主機寫入的同意(Claude 用量等):真主機存在 UserDefaults;Demo 主機的只在記憶體(HostsModel 預設)。
            hosts = HostsModel(
                store: KeychainHostStore(), demoChannel: demo, demoCompanions: Self.demoCompanions(demo),
                conversationCache: cache, preferences: preferences, hostIcons: hostIcons,
                selectionStore: UserDefaultsHostSelectionStore(), hostConsent: UserDefaultsHostWriteConsentStore(), credentials: credentials,
                // 裝置名稱只帶裝置種類(同公鑰註解),顯示在主機的裝置列表。
                hostService: .system(
                    deviceName: UIDevice.current.model,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
                hostServiceUpdates: HostServiceUpdates(store: UserDefaultsHostServiceUpdateStore()),
                push: push, tailscaleCheck: tailscaleCheck, swipeHint: UserDefaultsSwipeHintStore(),
                listMode: UserDefaultsAgentListModeStore()
            ) { endpoint, pin, credential in
                SSHHostChannel(
                    endpoint: endpoint, hostKeyPin: pin, credential: credential, tailscaleCheck: tailscaleCheck.observer,
                    // 連線診斷(#133):Console 篩 subsystem com.raychiu.purrdr、category ssh。
                    diagnostics: SSHConnectionLog.system(host: endpoint.host))
            }
        }
        hosts.haptics = SystemHaptics()
        hosts.reviewPrompt = Self.makeReviewPrompt(uiTesting: uiTesting)
        hosts.load()
        _hosts = State(initialValue: hosts)
        // 主機同步(#30):UI 測試不讀寫這台模擬器的 UserDefaults(後台是 backend.invalid,開啟時一律提示需要 Purrdr Plus)。
        hostSync = HostSyncModel(
            session: session, plus: plus, hosts: hosts, store: uiTesting ? InMemoryHostSyncStore() : UserDefaultsHostSyncStore())
        settings = Self.makeSettings(hosts: hosts)
        // UI 測試預設當作看過(不擋住其他測試);`-showWelcome` 測歡迎頁本身。
        welcome = WelcomeModel(store: uiTesting
            ? InMemoryWelcomeStore(hasSeen: !arguments.contains("-showWelcome")) : UserDefaultsWelcomeStore())
    }

    /// UI 測試的列表檢視(Spaces／Agents)存放處：預設只在記憶體(每次啟動都是 Spaces)。
    /// `-rememberListMode` 改存 UserDefaults(另一個 key,不碰正式的 `agentListMode`),測「重新啟動後記住」(#66);
    /// `-resetListMode` 先清掉上次留下的值。
    private static func uiTestingListMode(_ arguments: [String]) -> any AgentListModeStore {
        guard arguments.contains("-rememberListMode") else { return InMemoryAgentListModeStore() }
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

    /// UI 測試情境 `-seedUnpairedHTTPSHost`:主機同步帶來、這支裝置還沒配對的 HTTPS 主機(#63)。
    private static let unpairedHTTPSHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000003")!, name: "Studio HTTPS",
        hostService: HostServiceAddress("studio.tail1234.ts.net")!)

    private static func seededHosts(_ arguments: [String]) -> [HostConfiguration] {
        (arguments.contains("-seedHost") ? [seededHost] : []) + (arguments.contains("-seedUnreachableHost") ? [unreachableHost] : [])
            + (arguments.contains("-seedUnpairedHTTPSHost") ? [unpairedHTTPSHost] : [])
    }

    /// UI 測試情境(啟動旗標):桌機正在操作 Demo 的 Pane;Tailscale SSH check mode(一直等、或 3 秒後驗證完成);
    /// 對話紀錄一直讀不完(停在對話載入中，到讀取期限 20 秒為止);開啟 ledger 的對話 8 秒後、或每次送出 prompt 後 agent 一次寫出大量輸出(#130)。
    /// 情境只能選一個：旗標互斥，同時帶多個時只採用下面順序中的第一個。
    private static func demoScenario(_ arguments: [String]) -> DemoHost.Scenario {
        if arguments.contains("-demoPaneInUse") { return .paneInUse }
        if arguments.contains("-demoTailscaleCheck") { return .tailscaleCheck(completesAfter: nil) }
        if arguments.contains("-demoTailscaleCheckCompletes") { return .tailscaleCheck(completesAfter: .seconds(3)) }
        if arguments.contains("-demoTranscriptPending") { return .transcriptPending }
        if arguments.contains("-demoLargeOutput") { return .largeOutput(after: .seconds(8)) }
        if arguments.contains("-demoLargeOutputOnPrompt") { return .largeOutputOnPrompt }
        return .standard
    }

    /// UI 測試模式：權杖只放記憶體(不碰 Keychain)、後台指向不存在的位址(不連網路)。
    private static func makeMemberSession(uiTesting: Bool) -> MemberSession {
        let baseURL = uiTesting ? URL(string: "https://backend.invalid")! : BackendConfiguration.baseURL
        let tokenStore: any TokenStore = uiTesting ? InMemoryTokenStore() : KeychainTokenStore()
        return MemberSession(transport: URLSessionBackendTransport(baseURL: baseURL), tokenStore: tokenStore)
    }

    var body: some Scene {
        // 主視窗(三欄)。iPad 可以開好幾個，每個視窗有自己的導覽狀態;主機與 Agent 列表共用。
        WindowGroup(id: PurrdrCommands.mainWindowID) {
            TopNavigationView(
                hosts: hosts, member: member, settings: settings, plus: plus, hostSync: hostSync, notifications: PushAppDelegate.router,
                welcome: welcome)
        }
        .commands { PurrdrCommands() }
        // 「在新視窗開啟」的 Agent 對話或 Pane 終端機(#31)。
        WindowGroup(for: PaneWindow.self) { $window in
            if let window {
                PaneWindowView(window: window, hosts: hosts)
            }
        }
    }
}

