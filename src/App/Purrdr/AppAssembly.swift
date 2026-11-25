import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import SwiftUI
import UIKit

/// 組裝好的 app 狀態:畫面 model 與環境值。
struct AppRoot {
    let hosts: HostsModel
    let member: MemberModel
    let plus: SubscriptionModel
    let settings: SettingsModel
    let hostSync: HostSyncModel
    let welcome: WelcomeModel
    let inspectorStore: any InspectorVisibilityStore
    let hitchRecorder: DiagnosticRecorder
    /// 啟動提示「上次 Purrdr 意外關閉」(#632)。
    let crashNotice: CrashNoticeModel
    /// 要活著的訂閱者與監看物件。
    let hitchMetrics: HitchMetricKitSubscriber?
    let trafficMeter: TrafficMeter
    /// 第一個 frame 之後才開:流量存檔與主機名稱對應表的寫入等它(#590)。
    let launchGate: LaunchGate
    let trafficNetwork: TrafficNetworkMonitor
    let appLock: AppLock
    let inputSources: LaunchEnvironment.InputSources
    let viewFlags: LaunchEnvironment.ViewFlags
    let disablesAnimations: Bool
}

/// 把環境 adapter 交出的依賴(`LaunchEnvironment`)接成畫面 model(#565)。
/// 這裡不判斷正式或 UI 測試:兩個環境的差異都已在 adapter 裡決定。
@MainActor
enum AppAssembly {
    static func assemble(_ environment: LaunchEnvironment) -> AppRoot {
        let launchGate = LaunchGate()
        let session = environment.memberSession
        let localState = MemberLocalState(partition: environment.partition, session: session)
        let owner = environment.deviceOwner
        let confirmOwner: @MainActor @Sendable () async -> Bool = { await owner.confirmsAccountChange() }
        let member = MemberModel(
            session: session,
            google: GoogleSignIn(configuration: GoogleSignIn.Configuration(clientID: BackendConfiguration.googleClientID)),
            localState: localState,
            confirmOwner: confirmOwner,
            ownerVerificationAvailable: { owner.availability().canAuthenticate })
        let plus = SubscriptionModel(session: session, store: environment.plusStore, confirmOwner: confirmOwner)
        let push = PushService(
            session: session, platform: environment.push.platform, store: environment.push.store,
            loadDevice: environment.push.loadDevice,
            configuration: PushConfiguration(
                endpoint: PushSettings.endpoint, environment: PushSettings.environment, pluginSource: PushSettings.pluginSource),
            hostNames: environment.push.hostNames
        ) {
            await plus.refresh()
            return plus.isPlusActive
        }
        push.launchGate = launchGate
        if let sender = environment.push.testSender { push.testNotifications = sender }

        let hosts = HostsModel(environment.makeHosts(push))
        if environment.simulatesNoNetwork { hosts.simulatesNoNetwork = true }
        hosts.demoEntered = environment.demoEntry.initial
        hosts.demoEnteredDidChange = environment.demoEntry.didChange
        hosts.haptics = SystemHaptics()
        let trafficMeter = TrafficMeter(store: environment.trafficStore, launchGate: launchGate)
        environment.seedTraffic?(trafficMeter)
        let trafficNetwork = TrafficNetworkMonitor(meter: trafficMeter)
        hosts.trafficMeter = trafficMeter
        hosts.reviewPrompt = environment.reviewPrompt
        if let undoSendSeconds = environment.undoSendSeconds { hosts.undoSendSeconds = undoSendSeconds }
        hosts.load()

        let hostSync = HostSyncModel(session: session, plus: plus, hosts: hosts, store: environment.hostSyncStore)
        localState.attach(push: push, hostSync: hostSync, pushModels: { hosts.hostPushes.map(\.model) })
        let hitchRecorder = DiagnosticRecorder(sink: environment.hitchLog, defaults: .standard, system: { HitchSystemState.current() })
        var hitchMetrics: HitchMetricKitSubscriber?
        if environment.subscribesToMetricKit {
            CrashExceptionHandler.installAtLaunch(recorder: hitchRecorder)
            let subscriber = HitchMetricKitSubscriber(recorder: hitchRecorder)
            subscriber.start()
            hitchMetrics = subscriber
        }
        // `-uiTestingCrashRecord`:預放一筆「上次異常結束」的閃退記錄(#632)。
        if environment.recordsUITestingCrash { hitchRecorder.recordUITestingCrash() }
        let crashNotice = CrashNoticeModel(recorder: hitchRecorder, store: environment.crashNoticeStore)
        return AppRoot(
            hosts: hosts, member: member, plus: plus, settings: makeSettings(hosts: hosts, hitchRecorder: hitchRecorder),
            hostSync: hostSync, welcome: WelcomeModel(store: environment.welcomeStore), inspectorStore: environment.inspectorStore,
            hitchRecorder: hitchRecorder, crashNotice: crashNotice, hitchMetrics: hitchMetrics, trafficMeter: trafficMeter, launchGate: launchGate, trafficNetwork: trafficNetwork,
            appLock: environment.appLock, inputSources: environment.inputSources, viewFlags: environment.viewFlags,
            disablesAnimations: environment.disablesAnimations)
    }

    /// 設定頁。偏好存在 `UserDefaults.standard`(輸入列的 `@AppStorage` 讀同一個 key)。
    private static func makeSettings(hosts: HostsModel, hitchRecorder: DiagnosticRecorder) -> SettingsModel {
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
            // 主機數只算已存的主機,不含 Demo。
            app: app, hostCount: { hosts.hosts.count }, defaults: .standard,
            platform: SystemPlatformServices(), links: AppStoreConfiguration.settingsLinks, usageDisplay: hosts.usageDisplay,
            hitchRecorder: hitchRecorder
        )
    }
}
