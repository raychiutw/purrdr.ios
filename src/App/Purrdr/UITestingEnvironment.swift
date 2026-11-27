import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrDemo
import PurrdrFeatures
import PurrdrSSH
import SwiftUI
import UIKit

/// UI 測試環境 adapter(#565):以 `-uiTesting` 啟動,一律只用 Demo 主機:主機與偏好存在記憶體、不碰 Keychain、
/// 任何主機的通道也都是 Demo 主機、不連網路。各種測試情境由 `LaunchConfiguration` 的型別化值決定。
@MainActor
enum UITestingEnvironment {
    /// 閃退提示「已提示」狀態:放在專用的 suite(不碰正式設定),預設每次啟動重置;`keeping` 沿用上一次啟動留下的(#632)。
    private static func crashNoticeStore(keeping: Bool) -> any CrashNoticeStoring {
        let name = "com.raychiu.purrdr.ui-testing.crash-notice"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        if !keeping { defaults.removePersistentDomain(forName: name) }
        return UserDefaultsCrashNoticeStore(defaults: defaults)
    }

    static func make(_ configuration: LaunchConfiguration) -> LaunchEnvironment {
        // 清掉上一個測試留在 UserDefaults 的設定頁偏好,測試之間沒有順序依賴(#370)。
        if let domain = Bundle.main.bundleIdentifier {
            UITestingPreferences.resetPersistedState(in: .standard, domain: domain)
        }
        let tailscaleCheck = TailscaleCheckModel()
        let demo = DemoHost(scenario: configuration.demoScenario.demoHostScenario, tailscaleCheck: tailscaleCheck.observer)
        let partition = MemberPartition()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let usesFakeBackend = configuration.member.usesFakeBackend
        let seedTraffic: (@MainActor (TrafficMeter) -> Void)? = configuration.seedsDataUsage ? { @MainActor meter in UITestingEnvironment.seedLaunchTraffic(meter) } : nil
        let undoSendSeconds: @MainActor () -> Int = { configuration.undoSendCountdown ? 10 : 0 }
        let pushParts = LaunchEnvironment.PushParts(
            platform: UITestingPushPlatform(isAuthorized: usesFakeBackend), store: InMemoryPushPairingStore(partition: partition),
            loadDevice: {
                let model: PushDeviceModel = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
                return PushDeviceIdentity(id: PushDeviceID(rawValue: UITestingBackendTransport.thisDeviceID)!, name: model.rawValue, model: model)
            },
            hostNames: nil,
            testSender: UITestingPushTestSender(fails: configuration.pushTestFails))
        let inputSources = LaunchEnvironment.InputSources(
            pairingCodeScan: pairingCodeScanSource(configuration.pairingScan),
            recentPhotos: recentPhotoSource(configuration.recentPhotos),
            // `-uiTestingSimulatedVideo`:「影片」不開相簿挑選器(XCUITest 操作不了)(#474)。
            video: configuration.simulatesVideo ? .simulated : .system,
            // `-uiTestingSimulatedFileUpload`:檔案 tab 的上傳不開文件挑選器(#626)。
            fileUpload: configuration.simulatesFileUpload ? .simulated : .system)
        // `-uiTestingOversizedClipboard`:終端機貼上失敗的說明要有確定的觸發(#626)。
        if configuration.seedsOversizedClipboard {
            UIPasteboard.general.string = String(repeating: "x", count: 300 * 1024)
        }
        let viewFlags = LaunchEnvironment.ViewFlags(
            allowsTestingLinks: true, usesTestingSignIn: configuration.usesTestingSignIn,
            tracksReadingDrift: configuration.tracksReadingDrift)
        let hitchLog = DiagnosticLogFile(
            directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-ui-testing-hitch-\(UUID().uuidString)"))
        return LaunchEnvironment(
            // 關掉動畫,XCTest 每次互動前等動畫結束的 1 秒左右就不用等(#374);要驗動畫本身的測試帶 `-uiTestingAnimations`。
            disablesAnimations: configuration.disablesAnimations,
            memberSession: memberSession(configuration.member),
            partition: partition,
            // 轉移訂閱、撤銷其他裝置前確認是本人(#409);替身一律通過。
            deviceOwner: UITestingDeviceOwnerAuthenticator(hasPasscode: !configuration.hasNoPasscode),
            plusStore: UITestingPlusStore(hasCurrentTransaction: configuration.storeOwnedByOtherMember),
            // 預設開啟(Debug 的值),`-uiTestingPlusOff` 模擬上架版。
            plusAvailability: configuration.disablesPlus ? .disabled : .enabled,
            // 推播(#29):不請求權限、不註冊 APNs、配對只在記憶體;假後台的會員把通知權限當作已允許。
            push: pushParts,
            makeHosts: { push in hosts(configuration, demo: demo, tailscaleCheck: tailscaleCheck, push: push) },
            // `-demoNoNetwork`:裝置一直沒有網路(#221;Demo 主機同時斷網)。
            simulatesNoNetwork: configuration.simulatesNoNetwork,
            // UI 測試預設直接列 Demo,`-uiTestingNoHosts` 才看空狀態(#332);不留紀錄。
            demoEntry: LaunchEnvironment.DemoEntry(initial: !configuration.hasNoHosts, didChange: nil),
            trafficStore: InMemoryTrafficStore(days: configuration.seedsDataUsage ? seededTrafficDays() : []),
            seedTraffic: seedTraffic,
            // 只在記憶體計數、不叫出系統的評分對話框(會擋住後面的操作)。
            reviewPrompt: ReviewPrompt(store: InMemoryReviewPromptStore(), appVersion: version) {},
            // 送出可撤回(#300):預設關閉(其他測試送出不等倒數);`-uiTestingUndoSend` 開 10 秒倒數。
            undoSendSeconds: undoSendSeconds,
            // 主機同步:不讀寫這台模擬器的 UserDefaults(後台是 backend.invalid,開啟時一律提示需要 Purrdr Plus)。
            hostSyncStore: InMemoryHostSyncStore(partition: partition),
            // 每次啟動各用一個新資料夾:模擬器的 tmp 會跨測試保留,共用同一個資料夾會讓前面測試捲動留下的記錄
            // 殘留到「還沒有記錄」的測試(也會越積越大)。
            hitchLog: hitchLog,
            diagnosticEvents: .discarding,
            crashNoticeStore: Self.crashNoticeStore(keeping: configuration.keepsCrashNotice),
            recordsUITestingCrash: configuration.recordsUITestingCrash,
            subscribesToMetricKit: false,
            // 預設當作看過歡迎頁(不擋住其他測試);`-showWelcome` 測歡迎頁本身。
            welcomeStore: InMemoryWelcomeStore(hasSeen: !configuration.showsWelcome),
            inputSources: inputSources,
            viewFlags: viewFlags,
            appLock: appLock(configuration))
    }

    // MARK: 主機清單

    private static func hosts(
        _ configuration: LaunchConfiguration, demo: DemoHost, tailscaleCheck: TailscaleCheckModel, push: PushService
    ) -> HostsDependencies {
        // 祕密只放記憶體;裝置金鑰是軟體金鑰(模擬器沒有 Secure Enclave)。
        let credentials = HostCredentials(secrets: EphemeralHostSecretStore(), deviceKey: EphemeralDeviceKey())
        let seeded = configuration.seededHosts
        return HostsDependencies(
            stores: HostsStores(
                hosts: EphemeralHostStore(hosts: seededHosts(seeded)), selection: InMemoryHostSelectionStore(configuration.selectsDemo ? .demo : nil),
                currentHost: InMemoryCurrentHostStore(), planUsageSelection: InMemoryPlanUsageSelectionStore(),
                usageDisplay: UsageDisplaySetting(), hostPicker: InMemoryHostPickerStore(),
                // 每次啟動都從空白的釘選、靜音與主機圖示開始,不讀寫這台模擬器的 UserDefaults。
                chatPreferences: InMemoryHostChatPreferencesStore(), hostIcons: InMemoryHostIconStore(),
                conversationCache: MemoryFrontedConversationCache(base: InMemoryConversationCache()),
                skeletonRowCounts: InMemorySkeletonRowCountStore(), offlineQueues: InMemoryOfflineQueueStore(),
                hostConsent: InMemoryHostWriteConsentStore(), demoConsent: InMemoryHostWriteConsentStore()),
            demo: HostsDemo(
                channel: demo, files: DemoHostFileFetcher(),
                // 示範主機在 UI 測試要明確開啟(`-demoCompanions`),其他測試的列表才不會多出它們的列。
                companions: configuration.showsDemoCompanions ? DemoCompanions.make(demo) : []),
            connectivity: HostsConnectivity(
                credentials: credentials,
                // HTTPS 主機:配對不連網路,連線是 Demo 主機。`-demoOutdatedHostService`:主機服務是舊版(更新提示,#198)。
                hostService: .uiTesting(
                    channel: demo,
                    hostServiceVersion: configuration.hostServiceIsOutdated ? "0.0.1" : FixedHostServiceReleases.uiTestingLatestVersion,
                    pairedHosts: seeded.contains(.pairedHTTPS) ? [pairedHTTPSHost.id] : [],
                    readOnlyHosts: seeded.contains(.readOnlyHTTPS) ? [readOnlyHTTPSHost.id] : []),
                // 最新的主機服務版本固定,不連 GitHub(#362)。
                hostServiceUpdates: HostServiceUpdates(releases: FixedHostServiceReleases.uiTesting, store: InMemoryHostServiceUpdateStore()),
                tailscaleCheck: tailscaleCheck,
                // `-seedUnreachableHost` 的主機一律連不上(多主機情境:一台連不上不影響其他台);`-seedSlowHost` 的主機連線卡住(#221)。
                makeChannel: { endpoint, pin, _ in
                    if configuration.promptsHostKey, pin == nil { return DemoHostKeyPromptChannel() as any HostChannel }
                    if endpoint.host == unreachableHost.ssh?.endpoint.host { return DemoUnreachableChannel() as any HostChannel }
                    if endpoint.host == slowHost.ssh?.endpoint.host { return DemoUnreachableChannel(hangs: true) as any HostChannel }
                    return demo
                }),
            services: HostsServices(
                push: push,
                // UI 測試的圖片副本放暫存資料夾,不留在 app 的資料裡。
                attachmentStore: FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "Attachments")),
                // 模型目錄:UI 測試不給,不連網路。
                publicModelCatalog: nil,
                diagnostics: .system(category: "hosts"), sleep: Sleeping.task))
    }

    // MARK: 會員

    /// UI 測試模式:權杖只放記憶體(不碰 Keychain)、後台指向不存在的位址(不連網路)。
    /// 假後台的會員情境改用 app 的 `UITestingBackendTransport`(帳號頁的開通流程,#246)。
    private static func memberSession(_ scenario: LaunchConfiguration.MemberScenario) -> MemberSession {
        let deviceID: @Sendable () -> String? = { UITestingBackendTransport.thisDeviceID }
        switch scenario {
        case .loading:
            // 後台一直沒回應、本機沒有上次的會員資料:帳號頁停在第一次載入的骨架(#496)。
            return MemberSession(
                transport: UITestingHangingBackend(), tokenStore: InMemoryTokenStore(refreshToken: UITestingBackendTransport.refreshToken),
                deviceID: deviceID)
        case .offline:
            // 已登入過(有更新權杖與會員快照),但後台一律連不上:帳號頁「暫時連不上,你仍是登入狀態」。
            let tokens = InMemoryTokenStore(refreshToken: UITestingBackendTransport.refreshToken)
            try? tokens.setMemberSnapshot(Data(UITestingBackendTransport.memberJSON.utf8))
            return MemberSession(transport: UITestingOfflineBackend(), tokenStore: tokens, deviceID: deviceID)
        case .none:
            return MemberSession(
                transport: URLSessionBackendTransport(baseURL: URL(string: "https://backend.invalid")!), tokenStore: InMemoryTokenStore(),
                deviceID: deviceID, diagnostics: { _ in }, supportsSignInOnly: true)
        default:
            let backend = backendTransport(scenario)
            let seed = backend.startsWithStaleToken ? UITestingBackendTransport.staleRefreshToken : UITestingBackendTransport.refreshToken
            let tokens = backend.startsSignedIn ? InMemoryTokenStore(refreshToken: seed) : InMemoryTokenStore()
            return MemberSession(transport: backend, tokenStore: tokens, deviceID: deviceID, supportsSignInOnly: true)
        }
    }

    /// 假後台的各會員情境(只在 `scenario.usesFakeBackend` 時呼叫)。
    private static func backendTransport(_ scenario: LaunchConfiguration.MemberScenario) -> UITestingBackendTransport {
        switch scenario {
        case .plus: UITestingBackendTransport(isPlusActive: true)
        // 帳號頁 Plus 卡的各狀態(#409)。
        case .googlePlay: UITestingBackendTransport(scenario: .googlePlay)
        case .grace: UITestingBackendTransport(scenario: .grace)
        case .expired: UITestingBackendTransport(scenario: .expired)
        case .ownedByOtherMember: UITestingBackendTransport(scenario: .ownedByAnotherMember)
        case .pendingReview: UITestingBackendTransport(scenario: .pendingReview)
        // 帳號頁「登入方式」新增 Google 時發現它已屬另一個會員(合併確認,#410)。
        case .linkMerge(let blocked): UITestingBackendTransport(scenario: .none, linkFindsAnotherMember: true, mergeBlocked: blocked)
        // 從舊版升級(#414):舊的更新權杖被拒絕、要重新登入一次;重新登入後的訂閱有待處理的合併提示。
        case .upgraded: UITestingBackendTransport(scenario: .pendingReview, startsWithStaleToken: true)
        case .member: UITestingBackendTransport(isPlusActive: false)
        // 沒登入且這個帳號沒有會員:登入頁擋下並問要不要加入(#453)。
        case .noMember: UITestingBackendTransport(scenario: .none, startsSignedIn: false, hasNoMember: true)
        // 沒登入,按 Apple／Google 登入或註冊會直接登入假後台(登入與加入流程,#408)。
        case .signUp: UITestingBackendTransport(isPlusActive: false, startsSignedIn: false)
        case .none, .loading, .offline: preconditionFailure("沒有假後台的會員情境")
        }
    }

    // MARK: 輸入來源與 App 鎖

    /// App 鎖:UI 測試用替身與另一個 UserDefaults suite,`-uiTestingAppLock` 以已開啟啟動,`-uiTestingNoPasscode` 模擬沒有裝置密碼。
    private static func appLock(_ configuration: LaunchConfiguration) -> AppLock {
        let suiteName = "uiTesting.appLock"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(configuration.appLockEnabled, forKey: AppLock.enabledKey)
        return AppLock(authenticator: UITestingDeviceOwnerAuthenticator(hasPasscode: !configuration.hasNoPasscode), defaults: defaults)
    }

    /// 「＋」面板的替身照片;沒帶旗標就是沒有相簿權限。UI 測試一律不碰系統相簿。
    private static func recentPhotoSource(_ photos: LaunchConfiguration.RecentPhotos) -> RecentPhotoSource {
        switch photos {
        case .many: .simulated(count: 80)
        case .few: .simulated(count: 6)
        case .denied: .simulatedDenied
        }
    }

    /// `-uiTestingPairingScan`:掃描畫面一開就像掃到配對 QR code;`-uiTestingCameraDenied`:沒有相機權限。
    private static func pairingCodeScanSource(_ scan: LaunchConfiguration.PairingScan) -> PairingCodeScanSource {
        switch scan {
        case .cameraDenied: .simulatedCameraDenied
        case .camera: .camera
        case .simulated: .simulated(payload: "purrdr://pair?address=https%3A%2F%2Fstudio.tail1234.ts.net%3A8443&code=K7QM-2XPA")
        }
    }

    // MARK: 種子資料

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
    fileprivate static func seedLaunchTraffic(_ meter: TrafficMeter) {
        let id = seededHost.id.uuidString
        meter.setNetwork(.cellular)
        meter.record(hostID: id, direction: .sent, bytes: 500_000)
        meter.record(hostID: id, direction: .received, bytes: 1_500_000)
        meter.setNetwork(.wifi)
        meter.record(hostID: id, direction: .received, bytes: 8_000_000)
    }

    /// `-seedHost`:已存一台主機(通道仍是 Demo 主機),測主機清單的管理動作。
    private static let seededHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000001")!, name: "Studio Mac",
        endpoint: SSHEndpoint(host: "studio-mac", username: "demo"), operatingSystem: .macOS)

    /// `-seedUnreachableHost`:再存一台連不上的主機(多主機合併列表,#39)。
    private static let unreachableHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000002")!, name: "Build Box",
        endpoint: SSHEndpoint(host: "build-box.invalid", username: "demo"), operatingSystem: .linux)

    /// `-seedSlowHost`:再存一台連線卡住的主機(列表的「連線中」與「仍在連線」,#221)。
    private static let slowHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000004")!, name: "Slow Box",
        endpoint: SSHEndpoint(host: "slow-box.invalid", username: "demo"), operatingSystem: .linux)

    /// `-seedUnpairedHTTPSHost`:主機同步帶來、這支裝置還沒配對的 HTTPS 主機(#63)。
    private static let unpairedHTTPSHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000003")!, name: "Studio HTTPS",
        hostService: HostServiceAddress("studio.tail1234.ts.net")!)

    /// `-seedReadOnlyHTTPSHost`:這支裝置已用唯讀權杖配對好的 HTTPS 主機(主機頁的主機服務區塊,#290)。
    private static let readOnlyHTTPSHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000005")!, name: "Studio",
        hostService: HostServiceAddress("studio.tail1234.ts.net")!)

    /// `-seedPairedHTTPSHost`:這支裝置已配對好的 HTTPS 主機(主機頁的已配對裝置區塊,#291)。
    private static let pairedHTTPSHost = HostConfiguration(
        id: UUID(uuidString: "5EED0000-0000-4000-8000-000000000006")!, name: "Studio",
        hostService: HostServiceAddress("studio.tail1234.ts.net")!)

    private static func seededHosts(_ seeded: LaunchConfiguration.SeededHosts) -> [HostConfiguration] {
        (seeded.contains(.studioMac) ? [seededHost] : []) + (seeded.contains(.buildBox) ? [unreachableHost] : [])
            + (seeded.contains(.unpairedHTTPS) ? [unpairedHTTPSHost] : [])
            + (seeded.contains(.readOnlyHTTPS) ? [readOnlyHTTPSHost] : [])
            + (seeded.contains(.pairedHTTPS) ? [pairedHTTPSHost] : [])
            + (seeded.contains(.slowBox) ? [slowHost] : [])
    }
}
