import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrFeatures
import SwiftUI

/// 唯一的 composition root:組裝主機儲存、主機通道、Purrdr 後台與畫面 model。
///
/// 已存的主機經真 SSH(swift-nio-ssh)連線;沒有主機時用 Demo 主機。UI 測試以 `-uiTesting` 啟動，
/// 一律只用 Demo 主機：主機存在記憶體、不碰 Keychain,任何主機的通道也都是 Demo 主機，不連網路。
@main
struct PurrdrApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var hosts: HostsModel
    private let navigation = TopNavigationModel()
    private let member: MemberModel
    /// Purrdr Plus(#28)。跟會員共用同一個 `MemberSession`(同一組權杖)。
    private let plus: SubscriptionModel
    private let settings: SettingsModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let uiTesting = arguments.contains("-uiTesting")
        // Tailscale SSH check mode 的提示：所有主機通道共用。
        let tailscaleCheck = TailscaleCheckModel()
        let demo = DemoHost(scenario: Self.demoScenario(arguments), tailscaleCheck: tailscaleCheck.observer)
        // 對話快取。目前存在記憶體(app 執行期間);持久化(SwiftData)在之後的票。
        let cache = InMemoryConversationCache()
        // UI 測試每次啟動都從空白的釘選、靜音開始，不讀寫這台模擬器的 UserDefaults。
        let preferences: any ChatPreferencesStore = uiTesting
            ? InMemoryChatPreferencesStore() : UserDefaultsChatPreferencesStore()
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
                store: EphemeralHostStore(hosts: arguments.contains("-seedHost") ? [Self.seededHost] : []), demoChannel: demo,
                conversationCache: cache, preferences: preferences, selectionStore: InMemoryHostSelectionStore(),
                hostConsent: InMemoryHostWriteConsentStore(), credentials: credentials, push: push, tailscaleCheck: tailscaleCheck,
                makeChannel: { _, _, _ in demo })
        } else {
            // 公鑰註解只帶裝置種類(「iPhone」「iPad」),不帶使用者取的裝置名稱。
            let credentials = HostCredentials(
                secrets: KeychainHostSecretStore(), deviceKey: SecureEnclaveDeviceKey(comment: "purrdr@\(UIDevice.current.model)"))
            // 主機寫入的同意(Claude 用量等):真主機存在 UserDefaults;Demo 主機的只在記憶體(HostsModel 預設)。
            hosts = HostsModel(
                store: KeychainHostStore(), demoChannel: demo, conversationCache: cache, preferences: preferences,
                selectionStore: UserDefaultsHostSelectionStore(), hostConsent: UserDefaultsHostWriteConsentStore(), credentials: credentials,
                push: push, tailscaleCheck: tailscaleCheck
            ) { endpoint, pin, credential in
                SSHHostChannel(endpoint: endpoint, hostKeyPin: pin, credential: credential, tailscaleCheck: tailscaleCheck.observer)
            }
        }
        hosts.haptics = SystemHaptics()
        hosts.load()
        _hosts = State(initialValue: hosts)
        settings = Self.makeSettings(hosts: hosts)
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

    /// UI 測試情境(啟動旗標):桌機正在操作 Demo 的 Pane;Tailscale SSH check mode(一直等、或 3 秒後驗證完成)。
    private static func demoScenario(_ arguments: [String]) -> DemoHost.Scenario {
        if arguments.contains("-demoPaneInUse") { return .paneInUse }
        if arguments.contains("-demoTailscaleCheck") { return .tailscaleCheck(completesAfter: nil) }
        if arguments.contains("-demoTailscaleCheckCompletes") { return .tailscaleCheck(completesAfter: .seconds(3)) }
        return .standard
    }

    /// UI 測試模式：權杖只放記憶體(不碰 Keychain)、後台指向不存在的位址(不連網路)。
    private static func makeMemberSession(uiTesting: Bool) -> MemberSession {
        let baseURL = uiTesting ? URL(string: "https://backend.invalid")! : BackendConfiguration.baseURL
        let tokenStore: any TokenStore = uiTesting ? InMemoryTokenStore() : KeychainTokenStore()
        return MemberSession(transport: URLSessionBackendTransport(baseURL: baseURL), tokenStore: tokenStore)
    }

    var body: some Scene {
        WindowGroup {
            TopNavigationView(
                navigation: navigation, hosts: hosts, member: member, settings: settings, plus: plus, notifications: PushAppDelegate.router)
        }
    }
}
