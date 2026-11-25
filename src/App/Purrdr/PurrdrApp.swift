import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import SwiftUI
import UIKit

/// App 入口(#565):只做連接——解析啟動旗標、挑環境 adapter、組裝、交給畫面。
///
/// 正式啟動用 `ProductionEnvironment`(真 Keychain、真 SSH、真後台);UI 測試以 `-uiTesting` 啟動,
/// 用 `UITestingEnvironment`(只用 Demo 主機、記憶體存放、不連網路)。兩個 adapter 交出同一組依賴(`LaunchEnvironment`),
/// 由 `AppAssembly` 接成畫面 model。
@main
struct PurrdrApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var hosts: HostsModel
    private let root: AppRoot
    /// 進背景保留連線(#551):所有視窗都進背景、裝置沒鎖定才申請 background task。
    private let backgroundScheduler: SystemBackgroundTaskScheduler
    private let backgroundRetention: BackgroundRetentionController
    /// 所有場景合併的生命週期(App 鎖依它判斷離開多久)。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let configuration = LaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        let environment = configuration.isUITesting
            ? UITestingEnvironment.make(configuration) : ProductionEnvironment.make(configuration)
        if environment.disablesAnimations { UIView.setAnimationsEnabled(false) }
        let root = AppAssembly.assemble(environment)
        self.root = root
        let scheduler = SystemBackgroundTaskScheduler()
        backgroundScheduler = scheduler
        backgroundRetention = BackgroundRetentionController(scheduler: scheduler)
        _hosts = State(initialValue: root.hosts)
    }

    /// 進背景時把流量用量寫檔:以 background task 撐到背景佇列寫完,主執行緒不等。
    private func flushTrafficInBackground() {
        let task = UIApplication.shared.beginBackgroundTask(withName: "traffic.flush")
        root.trafficMeter.flushInBackground {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(task) }
        }
    }

    var body: some Scene {
        // 主視窗(三欄)。iPad 可以開好幾個，每個視窗有自己的導覽狀態;主機與 Agent 列表共用。
        WindowGroup(id: PurrdrCommands.mainWindowID) {
            TopNavigationView(
                hosts: hosts, member: root.member, settings: root.settings, plus: root.plus, hostSync: root.hostSync, notifications: PushAppDelegate.router,
                welcome: root.welcome, appLock: root.appLock, inspectorStore: root.inspectorStore)
            .appAppearance()
            .transaction { if root.disablesAnimations { $0.disablesAnimations = true; $0.animation = nil } }
            .appLockCover(root.appLock)
            .environment(\.pairingCodeScanSource, root.inputSources.pairingCodeScan)
            .environment(\.hitchRecorder, root.hitchRecorder)
            .environment(\.recentPhotoSource, root.inputSources.recentPhotos)
            .environment(\.videoSource, root.inputSources.video)
            .environment(\.forcesOpaqueGlass, root.viewFlags.forcesOpaqueGlass)
            .environment(\.skeletonAnimationsEnabled, !root.disablesAnimations)
            .environment(\.allowsTestingLinks, root.viewFlags.allowsTestingLinks)
            .environment(\.usesTestingSignIn, root.viewFlags.usesTestingSignIn)
            .environment(\.tracksReadingDrift, root.viewFlags.tracksReadingDrift)
            .environment(\.hidesDebugOverlay, root.viewFlags.hidesDebugOverlay)
        }
        .commands { PurrdrCommands() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            root.appLock.scenePhaseChanged(to: AppLockPhase(phase), at: .now)
            // 只在真的進背景時存(inactive 只是拉下通知中心等短暫狀態),且在背景佇列寫、不在主執行緒同步寫檔(#498)。
            if phase == .background {
                flushTrafficInBackground()
                backgroundRetention.didEnterBackground(isDeviceLocked: backgroundScheduler.isDeviceLocked)
            }
            if phase == .active { backgroundRetention.didBecomeActive() }
        }
        // 「在新視窗開啟」的 Agent 對話或 Pane 終端機(#31)。
        WindowGroup(for: PaneWindow.self) { $window in
            if let window {
                PaneWindowView(window: window, hosts: hosts)
                    .appAppearance()
                    .transaction { if root.disablesAnimations { $0.disablesAnimations = true; $0.animation = nil } }
                    .appLockCover(root.appLock)
                    .environment(\.tracksReadingDrift, root.viewFlags.tracksReadingDrift)
                    .environment(\.hidesDebugOverlay, root.viewFlags.hidesDebugOverlay)
            }
        }
    }
}

