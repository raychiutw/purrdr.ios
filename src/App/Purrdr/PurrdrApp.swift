import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrDemo
import PurrdrFeatures
import PurrdrNotificationContent
import PurrdrSSH
import StoreKit
import SwiftUI
import UIKit

/// 唯一的 composition root:組裝主機儲存、主機通道、Purrdr 後台與畫面 model。
///
/// 已存的主機經真 SSH(swift-nio-ssh)連線;沒有主機時用 Demo 主機。UI 測試以 `-uiTesting` 啟動，
/// 一律只用 Demo 主機：主機存在記憶體、不碰 Keychain,任何主機的通道也都是 Demo 主機，不連網路。
@main
struct PurrdrApp: App {
    /// UI 測試時關掉 UIKit 與 SwiftUI 的動畫(#374)。
    nonisolated(unsafe) static var disablesAnimations = false
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
    /// iPad 對話右側 Inspector 的開關偏好(#521);UI 測試預設關閉(`-uiTestingInspectorShown` 開),存在記憶體。
    private let inspectorStore: any InspectorVisibilityStore
    /// 配對碼掃描(#250):UI 測試以旗標模擬，不開真相機。
    private let pairingCodeScanSource: PairingCodeScanSource
    /// 捲動卡頓記錄器(只記數字,存在這支手機;設定頁可關閉、分享、清除)。
    private let hitchRecorder: HitchRecorder
    /// MetricKit 每日摘要(只在真實啟動訂閱;UI 測試不接)。
    private let hitchMetrics: HitchMetricKitSubscriber?
    private let recentPhotoSource: RecentPhotoSource
    private let videoSource: VideoSource
    /// UI 測試的 `-uiTestingReduceTransparency YES`:玻璃強制不透明。
    private let forcesOpaqueGlass: Bool
    /// `-uiTesting`:處理 `purrdr://testing-…` 測試連結(不重啟換字級)。
    private let allowsTestingLinks: Bool
    private let usesTestingSignIn: Bool
    /// App 鎖(#284):所有視窗共用一份鎖定狀態。
    private let appLock: AppLock
    /// 數據用量的流量計量(#353)與網路類型監看(監看物件要活著)。
    private let trafficMeter: TrafficMeter
    private let trafficNetwork: TrafficNetworkMonitor
    /// 所有場景合併的生命週期(App 鎖依它判斷離開多久)。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let uiTesting = arguments.contains("-uiTesting")
        // UI 測試(#370):清掉上一個測試留在 UserDefaults 的設定頁偏好,測試之間沒有順序依賴。
        if uiTesting, let domain = Bundle.main.bundleIdentifier {
            UITestingPreferences.resetPersistedState(in: .standard, domain: domain)
        }
        // UI 測試(#374):關掉動畫，XCTest 每次互動前等動畫結束的 1 秒左右就不用等。要驗動畫本身的測試帶 `-uiTestingAnimations`。
        Self.disablesAnimations = uiTesting && !arguments.contains("-uiTestingAnimations")
        if Self.disablesAnimations { UIView.setAnimationsEnabled(false) }
        // Tailscale SSH check mode 的提示：所有主機通道共用。
        let tailscaleCheck = TailscaleCheckModel()
        let demo = DemoHost(scenario: Self.demoScenario(arguments), tailscaleCheck: tailscaleCheck.observer)
        // 對話快取(#356):存在這支裝置的本機 SQLite(Caches,排除備份),重開 app 與從推播冷啟動打開聊天都先顯示。
        // UI 測試只放記憶體，不讀寫這台模擬器的檔案。
        // 前面再放一層記憶體快取(最近開過的聊天),打開聊天時同步還原,不閃骨架。
        let cache: any ConversationCache = MemoryFrontedConversationCache(
            base: uiTesting
                ? InMemoryConversationCache()
                : SQLiteConversationCache(file: URL.cachesDirectory.appending(path: "Purrdr/conversations.sqlite")))
        // UI 測試每次啟動都從空白的釘選、靜音與主機圖示開始，不讀寫這台模擬器的 UserDefaults。
        // 釘選、靜音依主機分開(#39);舊版沒有主機身分的資料在第一次啟動時丟棄。
        let preferences: any HostChatPreferencesStore = uiTesting
            ? InMemoryHostChatPreferencesStore() : UserDefaultsHostChatPreferencesStore()
        let hostIcons: any HostIconStore = uiTesting ? InMemoryHostIconStore() : UserDefaultsHostIconStore()
        let session = Self.makeMemberSession(uiTesting: uiTesting, arguments: arguments)
        // 通知與主機同步的本機狀態依會員分區(#405);升級時清掉舊的全域狀態(沒綁會員,登入後依會員重新整理)。
        let partition = MemberPartition()
        if !uiTesting { MemberLocalState.removeLegacyGlobalState() }
        let localState = MemberLocalState(partition: partition, session: session)
        // 轉移訂閱、撤銷其他裝置前確認是本人(#409);UI 測試的替身一律通過。
        let owner: any DeviceOwnerAuthenticating = uiTesting
            ? UITestingDeviceOwnerAuthenticator(hasPasscode: !arguments.contains("-uiTestingNoPasscode")) : SystemDeviceOwnerAuthenticator()
        let confirmOwner: @MainActor @Sendable () async -> Bool = { await owner.confirmsAccountChange() }
        member = MemberModel(
            session: session,
            google: GoogleSignIn(configuration: GoogleSignIn.Configuration(clientID: BackendConfiguration.googleClientID)),
            localState: localState,
            confirmOwner: confirmOwner,
            ownerVerificationAvailable: { owner.availability().canAuthenticate }
        )
        // StoreKit:在 Xcode 執行時，scheme 指定的 StoreKit 設定檔(src/App/Purrdr.storekit)提供商品，不連 App Store。
        // UI 測試用內容相同的替身(不連網路;命令列 xcodebuild test 不套用 StoreKit 設定檔)。
        let store: any PlusStore = uiTesting
            ? UITestingPlusStore(hasCurrentTransaction: arguments.contains("-uiTestingOwnedByOtherMember")) : StoreKitPlusStore()
        let plus = SubscriptionModel(session: session, store: store, confirmOwner: confirmOwner)
        self.plus = plus
        // 推播(#29):UI 測試不請求權限、不註冊 APNs、配對只在記憶體。
        let push = PushService(
            session: session,
            platform: uiTesting ? UITestingPushPlatform(isAuthorized: Self.uiTestingMemberBackend(arguments) != nil) : PushAppDelegate.platform,
            store: uiTesting ? InMemoryPushPairingStore(partition: partition) : UserDefaultsPushPairingStore(partition: partition),
            loadDevice: Self.pushDevice(uiTesting: uiTesting),
            configuration: PushConfiguration(
                endpoint: PushSettings.endpoint, environment: PushSettings.environment, pluginSource: PushSettings.pluginSource),
            // 主機名稱對應表放 App Group,Notification Service Extension 用它補通知副標題(#431;UI 測試不寫)。
            hostNames: uiTesting ? nil : UserDefaultsPushHostNames()
        ) {
            await plus.refresh()
            return plus.isPlusActive
        }
        // 測試通知:後台與主機外掛目前沒有這條路徑,正式 app 不提供;UI 測試用替身演出成功與失敗。
        if uiTesting { push.testNotifications = UITestingPushTestSender(fails: arguments.contains("-uiTestingPushTestFails")) }
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
                    hostServiceVersion: arguments.contains("-demoOutdatedHostService")
                        ? "0.0.1" : FixedHostServiceReleases.uiTestingLatestVersion,
                    pairedHosts: arguments.contains("-seedPairedHTTPSHost") ? [Self.pairedHTTPSHost.id] : [],
                    readOnlyHosts: arguments.contains("-seedReadOnlyHTTPSHost") ? [Self.readOnlyHTTPSHost.id] : []),
                // 最新的主機服務版本固定，不連 GitHub(#362)。
                hostServiceUpdates: HostServiceUpdates(releases: FixedHostServiceReleases.uiTesting, store: InMemoryHostServiceUpdateStore()),
                push: push, tailscaleCheck: tailscaleCheck,
                // UI 測試的圖片副本放暫存資料夾，不留在 app 的資料裡。
                attachmentStore: FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "Attachments")),
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
                selectionStore: UserDefaultsHostSelectionStore(), currentHost: UserDefaultsCurrentHostStore(), planUsageSelection: UserDefaultsPlanUsageSelectionStore(),
                usageDisplay: UsageDisplaySetting(defaults: .standard),
                hostPicker: UserDefaultsHostPickerStore(),
                hostConsent: UserDefaultsHostWriteConsentStore(), credentials: credentials,
                // 裝置名稱只帶裝置種類(同公鑰註解),顯示在主機的裝置列表。
                hostService: .system(
                    deviceName: UIDevice.current.model,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
                // 最新的主機服務版本從 purrdr.host 的 GitHub Release 取得，主機服務發版時 app 不用改版號(#362)。
                hostServiceUpdates: HostServiceUpdates(releases: GitHubHostServiceReleases(), store: UserDefaultsHostServiceUpdateStore()),
                push: push, tailscaleCheck: tailscaleCheck,
                skeletonRowCounts: UserDefaultsSkeletonRowCountStore(),
                // 離線佇列存在本機，App 重開仍在(#301)。
                offlineQueues: UserDefaultsOfflineQueueStore(),
                // 模型目錄的公開來源(#385);UI 測試不給,不連網路。
                publicModelCatalog: URLSessionPublicModelCatalog()
            ) { endpoint, pin, credential in
                SSHHostChannel(
                    endpoint: endpoint, hostKeyPin: pin, credential: credential, tailscaleCheck: tailscaleCheck.observer,
                    // 連線診斷(#133):Console 篩 subsystem com.raychiu.purrdr、category ssh。
                    diagnostics: SSHConnectionLog.system(host: endpoint.host))
            }
        }
        // `-demoNoNetwork`:裝置一直沒有網路(#221;Demo 主機同時斷網)。
        if uiTesting, arguments.contains("-demoNoNetwork") { hosts.simulatesNoNetwork = true }
        // 沒有主機時的空狀態(#332):正式啟動一律從空狀態開始;UI 測試預設直接列 Demo,`-uiTestingNoHosts` 才看空狀態。
        // 正式啟動沿用上次的選擇(#394:啟用後才出現在主機選單,移除後不再出現);UI 測試不留紀錄。
        let demoKey = "demoHostEnabled"
        if uiTesting {
            hosts.demoEntered = !arguments.contains("-uiTestingNoHosts")
        } else {
            hosts.demoEntered = UserDefaults.standard.bool(forKey: demoKey)
            hosts.demoEnteredDidChange = { UserDefaults.standard.set($0, forKey: demoKey) }
        }
        hosts.haptics = SystemHaptics()
        // 流量計量(#353):存在 Application Support(只在這支裝置;UI 測試只放記憶體)。
        let trafficStore: any TrafficStore = uiTesting
            ? InMemoryTrafficStore(days: arguments.contains("-seedDataUsage") ? Self.seededTrafficDays() : [])
            : FileTrafficStore(url: URL.applicationSupportDirectory.appending(path: "traffic-usage.json"))
        let trafficMeter = TrafficMeter(store: trafficStore)
        if uiTesting, arguments.contains("-seedDataUsage") { Self.seedLaunchTraffic(trafficMeter) }
        trafficNetwork = TrafficNetworkMonitor(meter: trafficMeter)
        self.trafficMeter = trafficMeter
        hosts.trafficMeter = trafficMeter
        hosts.reviewPrompt = Self.makeReviewPrompt(uiTesting: uiTesting)
        // 送出可撤回(#300):UI 測試預設關閉(其他測試送出不等倒數);`-uiTestingUndoSend` 開 10 秒倒數(來得及點撤回)。
        if uiTesting { hosts.undoSendSeconds = { arguments.contains("-uiTestingUndoSend") ? 10 : 0 } }
        hosts.load()
        _hosts = State(initialValue: hosts)
        // 主機同步(#30):UI 測試不讀寫這台模擬器的 UserDefaults(後台是 backend.invalid,開啟時一律提示需要 Purrdr Plus)。
        let hostSync = HostSyncModel(
            session: session, plus: plus, hosts: hosts,
            store: uiTesting ? InMemoryHostSyncStore(partition: partition) : UserDefaultsHostSyncStore(partition: partition))
        self.hostSync = hostSync
        localState.attach(push: push, hostSync: hostSync, pushModels: { hosts.hostPushes.map(\.model) })
        let hitchStore = uiTesting
            ? HitchLogFile(directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-ui-testing-hitch"))
            : HitchLogFile.applicationSupport()
        let hitchRecorder = HitchRecorder(sink: hitchStore, defaults: .standard, system: { HitchSystemState.current() })
        self.hitchRecorder = hitchRecorder
        if uiTesting {
            hitchMetrics = nil
        } else {
            let subscriber = HitchMetricKitSubscriber(recorder: hitchRecorder)
            subscriber.start()
            hitchMetrics = subscriber
        }
        settings = Self.makeSettings(hosts: hosts, hitchRecorder: hitchRecorder)
        // UI 測試預設當作看過(不擋住其他測試);`-showWelcome` 測歡迎頁本身。
        welcome = WelcomeModel(store: uiTesting
            ? InMemoryWelcomeStore(hasSeen: !arguments.contains("-showWelcome")) : UserDefaultsWelcomeStore())
        inspectorStore = uiTesting
            ? InMemoryInspectorVisibilityStore(isShown: arguments.contains("-uiTestingInspectorShown"))
            : UserDefaultsInspectorVisibilityStore()
        pairingCodeScanSource = Self.pairingCodeScanSource(arguments)
        recentPhotoSource = uiTesting ? Self.recentPhotoSource(arguments) : .system
        // `-uiTestingSimulatedVideo`:「影片」不開相簿挑選器(XCUITest 操作不了)，直接給一支小影片(#474)。
        videoSource = uiTesting && arguments.contains("-uiTestingSimulatedVideo") ? .simulated : .system
        allowsTestingLinks = uiTesting
        usesTestingSignIn = uiTesting
            && (arguments.contains("-uiTestingSignUp") || arguments.contains("-uiTestingNoMember") || arguments.contains("-uiTestingLinkMerge")
                || arguments.contains("-uiTestingLinkMergeBlocked") || arguments.contains("-uiTestingUpgradedMember"))
        forcesOpaqueGlass = uiTesting && UserDefaults.standard.bool(forKey: "uiTestingReduceTransparency")
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

    /// `-uiTestingRecentPhotos`:「＋」面板有 6 張替身照片;沒帶(`-uiTestingPhotosDenied` 或預設)就是沒有相簿權限。UI 測試一律不碰系統相簿。
    private static func recentPhotoSource(_ arguments: [String]) -> RecentPhotoSource {
        arguments.contains("-uiTestingManyRecentPhotos") ? .simulated(count: 80)
            : arguments.contains("-uiTestingRecentPhotos") ? .simulated(count: 6) : .simulatedDenied
    }

    /// `-uiTestingPairingScan`:掃描畫面一開就像掃到配對 QR code;`-uiTestingCameraDenied`:沒有相機權限。
    private static func pairingCodeScanSource(_ arguments: [String]) -> PairingCodeScanSource {
        if arguments.contains("-uiTestingCameraDenied") { return .simulatedCameraDenied }
        guard arguments.contains("-uiTestingPairingScan") else { return .camera }
        return .simulated(payload: "purrdr://pair?address=https%3A%2F%2Fstudio.tail1234.ts.net%3A8443&code=K7QM-2XPA")
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
    private static func makeSettings(hosts: HostsModel, hitchRecorder: HitchRecorder) -> SettingsModel {
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
            // 主機數只算已存的主機，不含 Demo。
            app: app, hostCount: { hosts.hosts.count }, defaults: .standard,
            platform: SystemPlatformServices(), links: AppStoreConfiguration.settingsLinks, usageDisplay: hosts.usageDisplay,
            hitchRecorder: hitchRecorder
        )
    }

    /// UI 測試情境 `-seedDataUsage`(#354):過去 29 天的用量(Studio Mac 每天 Wi-Fi 20 MB 加行動網路 3 MB、Build Box 每天 1 MB、
    /// 已刪除的主機 2 MB),搭配 `-seedHost`、`-seedUnreachableHost`。
    private static func seededTrafficDays() -> [TrafficDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (1...29).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            return TrafficDay(day: key, hosts: [
                seededHost.id.uuidString: [
                    .wifi: TrafficBytes(sent: 2_000_000, received: 18_000_000),
                    .cellular: TrafficBytes(sent: 1_000_000, received: 2_000_000),
                ],
                unreachableHost.id.uuidString: [.wifi: TrafficBytes(sent: 0, received: 1_000_000)],
                "9E9E9E9E-0000-4000-8000-000000000001": [.wifi: TrafficBytes(sent: 0, received: 2_000_000)],
            ])
        }
    }

    /// 今天與這次開啟:Studio Mac 行動網路 2 MB(送出 0.5、收到 1.5)加 Wi-Fi 收到 8 MB,共 10 MB。
    private static func seedLaunchTraffic(_ meter: TrafficMeter) {
        let id = seededHost.id.uuidString
        meter.setNetwork(.cellular)
        meter.record(hostID: id, direction: .sent, bytes: 500_000)
        meter.record(hostID: id, direction: .received, bytes: 1_500_000)
        meter.setNetwork(.wifi)
        meter.record(hostID: id, direction: .received, bytes: 8_000_000)
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
    /// 對話紀錄一直讀不完(停在對話載入中，到讀取期限 20 秒為止);開啟 ledger 的對話 5 秒後、或每次送出 prompt 後 agent 一次寫出大量輸出(#130);
    /// 對話載入完成 1 秒後斷網(立刻失敗，或每個指令等 10 秒才失敗,#219);啟動就沒有網路(每個指令等 10 秒才失敗,#221)。
    /// 情境只能選一個：旗標互斥，同時帶多個時只採用下面順序中的第一個。
    private static func demoScenario(_ arguments: [String]) -> DemoHost.Scenario {
        if arguments.contains("-demoPaneInUse") { return .paneInUse }
        if arguments.contains("-demoTailscaleCheck") { return .tailscaleCheck(completesAfter: nil) }
        if arguments.contains("-demoTailscaleCheckCompletes") { return .tailscaleCheck(completesAfter: .seconds(3)) }
        if arguments.contains("-demoTranscriptPending") { return .transcriptPending }
        if arguments.contains("-demoLargeOutput") { return .largeOutput(after: .seconds(5)) }
        if arguments.contains("-demoLargeOutputOnPrompt") { return .largeOutputOnPrompt }
        if arguments.contains("-demoToolBurst") { return .toolBurst(after: .seconds(10)) }
        if arguments.contains("-demoWorkingAfterPrompt") { return .workingAfterPrompt(for: .seconds(15)) }
        if arguments.contains("-demoAgentFiles") { return .agentFiles }
        if arguments.contains("-demoSentImages") { return .sentImages }
        if arguments.contains("-demoAntigravity") { return .antigravity }
        if arguments.contains("-demoGoesOffline") { return .goesOffline(after: .seconds(1), hangs: false) }
        if arguments.contains("-demoGoesOfflineHanging") { return .goesOffline(after: .seconds(1), hangs: true) }
        if arguments.contains("-demoNoNetwork") { return .goesOffline(after: .zero, hangs: true) }
        return .standard
    }

    /// 登入時帶給後台的這支裝置 id:正式是推播共用的 Keychain id,UI 測試是固定值。
    private static func memberDeviceID(uiTesting: Bool) -> @Sendable () -> String? {
        if uiTesting { return { UITestingBackendTransport.thisDeviceID } }
        return {
            guard let id = try? KeychainPushDeviceID().load() else { return nil }
            return id.backendValue
        }
    }

    /// UI 測試模式：權杖只放記憶體(不碰 Keychain)、後台指向不存在的位址(不連網路)。
    /// `-uiTestingMember`／`-uiTestingPlusMember`:改用假後台，以已登入的會員啟動(帳號頁的開通流程,#246)。
    private static func makeMemberSession(uiTesting: Bool, arguments: [String]) -> MemberSession {
        // 登入時帶這支裝置的 id(與推播共用,Keychain);讀不到時不帶,照常登入。UI 測試用固定 id。
        let deviceID = memberDeviceID(uiTesting: uiTesting)
        if uiTesting, arguments.contains("-uiTestingMemberLoading") {
            // 後台一直沒回應、本機沒有上次的會員資料:帳號頁停在第一次載入的骨架(#496)。
            return MemberSession(
                transport: UITestingHangingBackend(), tokenStore: InMemoryTokenStore(refreshToken: UITestingBackendTransport.refreshToken),
                deviceID: deviceID)
        }
        if uiTesting, arguments.contains("-uiTestingMemberOffline") {
            // 已登入過(有更新權杖與會員快照),但後台一律連不上:帳號頁「暫時連不上,你仍是登入狀態」。
            let tokens = InMemoryTokenStore(refreshToken: UITestingBackendTransport.refreshToken)
            try? tokens.setMemberSnapshot(Data(UITestingBackendTransport.memberJSON.utf8))
            return MemberSession(transport: UITestingOfflineBackend(), tokenStore: tokens, deviceID: deviceID)
        }
        if uiTesting, let backend = uiTestingMemberBackend(arguments) {
            let seed = backend.startsWithStaleToken ? UITestingBackendTransport.staleRefreshToken : UITestingBackendTransport.refreshToken
            let tokens = backend.startsSignedIn ? InMemoryTokenStore(refreshToken: seed) : InMemoryTokenStore()
            return MemberSession(transport: backend, tokenStore: tokens, deviceID: deviceID, supportsSignInOnly: true)
        }
        let baseURL = uiTesting ? URL(string: "https://backend.invalid")! : BackendConfiguration.baseURL
        let tokenStore: any TokenStore = uiTesting ? InMemoryTokenStore() : KeychainTokenStore()
        var diagnostics: MemberDiagnostics = MemberLog.system
        if uiTesting { diagnostics = { _ in } }
        return MemberSession(
            transport: URLSessionBackendTransport(baseURL: baseURL), tokenStore: tokenStore, deviceID: deviceID,
            diagnostics: diagnostics,
            // 後台 `createMember: false`(purrdr.server#34 已上線):登入頁查無會員不新建,改問要不要加入(#434、#453)。
            supportsSignInOnly: true)
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
        // 帳號頁 Plus 卡的各狀態(#409)。
        let scenarios: [(flag: String, scenario: UITestingBackendTransport.Scenario)] = [
            ("-uiTestingGooglePlayMember", .googlePlay), ("-uiTestingGraceMember", .grace), ("-uiTestingExpiredMember", .expired),
            ("-uiTestingOwnedByOtherMember", .ownedByAnotherMember), ("-uiTestingPendingReviewMember", .pendingReview),
        ]
        if let match = scenarios.first(where: { arguments.contains($0.flag) }) { return UITestingBackendTransport(scenario: match.scenario) }
        // 帳號頁「登入方式」新增 Google 時發現它已屬另一個會員(合併確認,#410)。
        if arguments.contains("-uiTestingLinkMerge") || arguments.contains("-uiTestingLinkMergeBlocked") {
            return UITestingBackendTransport(
                scenario: .none, linkFindsAnotherMember: true, mergeBlocked: arguments.contains("-uiTestingLinkMergeBlocked"))
        }
        // 從舊版升級(#414):舊的更新權杖被拒絕、要重新登入一次;重新登入後的訂閱有待處理的合併提示。
        if arguments.contains("-uiTestingUpgradedMember") {
            return UITestingBackendTransport(scenario: .pendingReview, startsWithStaleToken: true)
        }
        if arguments.contains("-uiTestingMember") { return UITestingBackendTransport(isPlusActive: false) }
        // 沒登入,按 Apple／Google 登入或註冊會直接登入假後台(登入與加入流程,#408)。
        // 沒登入且這個帳號沒有會員:登入頁擋下並問要不要加入(#453)。
        if arguments.contains("-uiTestingNoMember") {
            return UITestingBackendTransport(scenario: .none, startsSignedIn: false, hasNoMember: true)
        }
        if arguments.contains("-uiTestingSignUp") { return UITestingBackendTransport(isPlusActive: false, startsSignedIn: false) }
        return nil
    }

    /// 進背景時把流量用量寫檔:以 background task 撐到背景佇列寫完,主執行緒不等。
    private func flushTrafficInBackground() {
        let task = UIApplication.shared.beginBackgroundTask(withName: "traffic.flush")
        trafficMeter.flushInBackground {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(task) }
        }
    }

    var body: some Scene {
        // 主視窗(三欄)。iPad 可以開好幾個，每個視窗有自己的導覽狀態;主機與 Agent 列表共用。
        WindowGroup(id: PurrdrCommands.mainWindowID) {
            TopNavigationView(
                hosts: hosts, member: member, settings: settings, plus: plus, hostSync: hostSync, notifications: PushAppDelegate.router,
                welcome: welcome, appLock: appLock, inspectorStore: inspectorStore)
            .appAppearance()
            .transaction { if Self.disablesAnimations { $0.disablesAnimations = true; $0.animation = nil } }
            .appLockCover(appLock)
            .environment(\.pairingCodeScanSource, pairingCodeScanSource)
            .environment(\.hitchRecorder, hitchRecorder)
            .environment(\.recentPhotoSource, recentPhotoSource)
            .environment(\.videoSource, videoSource)
            .environment(\.forcesOpaqueGlass, forcesOpaqueGlass)
            .environment(\.skeletonAnimationsEnabled, !Self.disablesAnimations)
            .environment(\.allowsTestingLinks, allowsTestingLinks)
            .environment(\.usesTestingSignIn, usesTestingSignIn)
        }
        .commands { PurrdrCommands() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            appLock.scenePhaseChanged(to: AppLockPhase(phase), at: .now)
            // 只在真的進背景時存(inactive 只是拉下通知中心等短暫狀態),且在背景佇列寫、不在主執行緒同步寫檔(#498)。
            if phase == .background { flushTrafficInBackground() }
        }
        // 「在新視窗開啟」的 Agent 對話或 Pane 終端機(#31)。
        WindowGroup(for: PaneWindow.self) { $window in
            if let window {
                PaneWindowView(window: window, hosts: hosts)
                    .appAppearance()
                    .transaction { if Self.disablesAnimations { $0.disablesAnimations = true; $0.animation = nil } }
                    .appLockCover(appLock)
            }
        }
    }
}

