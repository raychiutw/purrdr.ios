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

/// 正式環境 adapter(#565):真 Keychain、真 SSH、真後台、真 StoreKit。
/// `-demo*` 情境旗標在正式啟動也有效(Demo 主機的內容),其餘 UI 測試旗標一律忽略。
@MainActor
enum ProductionEnvironment {
    static func make(_ configuration: LaunchConfiguration) -> LaunchEnvironment {
        // 重裝清理(#580):刪 App 後 Keychain 項目還在;必須在任何 Keychain 存放區被讀之前。
        ReinstallGuard.system().run()
        // Tailscale SSH check mode 的提示:所有主機通道共用。
        let tailscaleCheck = TailscaleCheckModel()
        // 診斷事件(#688):連線事件進可分享的診斷檔,受「操作記錄」開關控制(閃退照舊一律記錄)。
        let hitchLog = DiagnosticLogFile.applicationSupport()
        let diagnosticEvents = DiagnosticEvents(
            sink: hitchLog, isEnabled: { HitchLogSettings.isEnabled(.standard) }, ordinals: .userDefaults(.standard))
        let demo = DemoHost(scenario: configuration.demoScenario.demoHostScenario, tailscaleCheck: tailscaleCheck.observer)
        // 對話快取(#356):存在這支裝置的本機 SQLite(Caches,排除備份);前面再放一層記憶體快取(最近開過的聊天)。
        let cache: any ConversationCache = MemoryFrontedConversationCache(
            base: SQLiteConversationCache(file: URL.cachesDirectory.appending(path: "Purrdr/conversations.sqlite")))
        // 通知與主機同步的本機狀態依會員分區(#405);升級時清掉舊的全域狀態(沒綁會員,登入後依會員重新整理)。
        let partition = MemberPartition()
        MemberLocalState.removeLegacyGlobalState()
        let session = MemberSession(
            transport: URLSessionBackendTransport(baseURL: BackendConfiguration.baseURL), tokenStore: KeychainTokenStore(),
            deviceID: {
                // 登入時帶這支裝置的 id(與推播共用,Keychain);讀不到時不帶,照常登入。
                guard let id = try? KeychainPushDeviceID().load() else { return nil }
                return id.backendValue
            },
            diagnostics: MemberLog.events(diagnosticEvents),
            // 後台 `createMember: false`(purrdr.server#34 已上線):登入頁查無會員不新建,改問要不要加入(#434、#453)。
            supportsSignInOnly: true)
        let demoKey = "demoHostEnabled"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return LaunchEnvironment(
            disablesAnimations: false,
            memberSession: session,
            partition: partition,
            deviceOwner: SystemDeviceOwnerAuthenticator(),
            // StoreKit:在 Xcode 執行時,scheme 指定的 StoreKit 設定檔(src/App/Purrdr.storekit)提供商品,不連 App Store。
            plusStore: StoreKitPlusStore(),
            push: LaunchEnvironment.PushParts(
                platform: PushAppDelegate.platform, store: UserDefaultsPushPairingStore(partition: partition),
                // 這支裝置(#266):推播 id 存 Keychain(讀不到時稍後再試),名稱預設是系統的裝置名稱。
                loadDevice: {
                    let model: PushDeviceModel = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
                    let name = PushDeviceIdentity.validName(UIDevice.current.name) ?? model.rawValue
                    return PushDeviceIdentity(id: try KeychainPushDeviceID().load(), name: name, model: model)
                },
                // 主機名稱對應表放 App Group,Notification Service Extension 用它補通知副標題(#431)。
                hostNames: UserDefaultsPushHostNames(),
                // 測試通知:後台與主機外掛目前沒有這條路徑,正式 app 不提供。
                testSender: nil),
            makeHosts: { push in
                // 公鑰註解只帶裝置種類(「iPhone」「iPad」),不帶使用者取的裝置名稱。
                let credentials = HostCredentials(
                    secrets: KeychainHostSecretStore(), deviceKey: SecureEnclaveDeviceKey(comment: "purrdr@\(UIDevice.current.model)"))
                // 釘選、靜音依主機分開(#39);舊版沒有主機身分的資料在第一次啟動時丟棄。
                let skeletonRowCounts = UserDefaultsSkeletonRowCountStore()
                return HostsDependencies(
                    stores: HostsStores(
                        hosts: KeychainHostStore(), selection: UserDefaultsHostSelectionStore(), currentHost: UserDefaultsCurrentHostStore(),
                        planUsageSelection: UserDefaultsPlanUsageSelectionStore(), usageDisplay: UsageDisplaySetting(defaults: .standard),
                        hostPicker: UserDefaultsHostPickerStore(), chatPreferences: UserDefaultsHostChatPreferencesStore(),
                        hostIcons: UserDefaultsHostIconStore(), conversationCache: cache, skeletonRowCounts: skeletonRowCounts,
                        // 離線佇列存在 Keychain(僅此裝置、不進備份),App 重開仍在(#301、#575)。
                        offlineQueues: ProtectedOfflineQueueStore.system(),
                        // 主機寫入的同意(Claude 方案用量等):真主機存在 UserDefaults;Demo 主機的只在記憶體。
                        hostConsent: UserDefaultsHostWriteConsentStore(), demoConsent: InMemoryHostWriteConsentStore()),
                    demo: HostsDemo(channel: demo, files: DemoHostFileFetcher(), companions: DemoCompanions.make(demo)),
                    connectivity: HostsConnectivity(
                        credentials: credentials,
                        // 裝置名稱只帶裝置種類(同公鑰註解),顯示在主機的裝置列表。
                        hostService: .system(
                            deviceName: UIDevice.current.model,
                            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                            diagnostics: diagnosticEvents),
                        // 最新的主機服務版本從 purrdr.host 的 GitHub Release 取得,主機服務發版時 app 不用改版號(#362)。
                        hostServiceUpdates: HostServiceUpdates(releases: GitHubHostServiceReleases(), store: UserDefaultsHostServiceUpdateStore()),
                        tailscaleCheck: tailscaleCheck,
                        makeChannel: { endpoint, pin, credential in
                            SSHHostChannel(
                                endpoint: endpoint, hostKeyPin: pin, credential: credential, tailscaleCheck: tailscaleCheck.observer,
                                // 連線診斷(#133):Console 篩 subsystem com.raychiu.purrdr、category ssh。
                                diagnostics: SSHConnectionLog.events(diagnosticEvents, host: endpoint.host))
                        }),
                    services: HostsServices(
                        push: push, attachmentStore: FileAttachmentStore.app(),
                        // 模型目錄的公開來源(#385)。
                        publicModelCatalog: URLSessionPublicModelCatalog(),
                        diagnostics: .system(category: "hosts"), sleep: Sleeping.task))
            },
            simulatesNoNetwork: false,
            // 正式啟動沿用上次的選擇(#394:啟用後才出現在主機選單,移除後不再出現)。
            demoEntry: LaunchEnvironment.DemoEntry(
                initial: UserDefaults.standard.bool(forKey: demoKey), didChange: { UserDefaults.standard.set($0, forKey: demoKey) }),
            // 流量計量(#353):存在 Application Support(只在這支裝置)。
            trafficStore: FileTrafficStore(url: URL.applicationSupportDirectory.appending(path: "traffic-usage.json")),
            seedTraffic: nil,
            // 成功送出幾次 prompt 後請求評分(#34)。
            reviewPrompt: ReviewPrompt(store: UserDefaultsReviewPromptStore(), appVersion: version) {
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
                AppStore.requestReview(in: scene)
            },
            undoSendSeconds: nil,
            hostSyncStore: UserDefaultsHostSyncStore(partition: partition),
            hitchLog: hitchLog,
            diagnosticEvents: diagnosticEvents,
            crashNoticeStore: UserDefaultsCrashNoticeStore(),
            recordsUITestingCrash: false,
            subscribesToMetricKit: true,
            welcomeStore: UserDefaultsWelcomeStore(),
            inputSources: LaunchEnvironment.InputSources(pairingCodeScan: .camera, recentPhotos: .system, video: .system, fileUpload: .system),
            viewFlags: LaunchEnvironment.ViewFlags(
                allowsTestingLinks: false, usesTestingSignIn: false, tracksReadingDrift: false),
            appLock: AppLock(authenticator: SystemDeviceOwnerAuthenticator(), defaults: .standard))
    }
}
