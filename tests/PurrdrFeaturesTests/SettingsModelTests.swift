import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 設定頁(行為規格 F15;#2 故事 115、116;#37 故事 46)。
@MainActor
@Suite("設定")
struct SettingsModelTests {
    static let app = AppInfo(version: "1.2.3", build: "45", system: "iOS 26.1", device: "iPhone")

    /// 記錄平台服務收到的呼叫(Seam 3)。
    @MainActor
    final class RecordingPlatform: PlatformServices {
        var opened: [URL] = []
        var copied: [String] = []
        func open(_ url: URL) { opened.append(url) }
        func copy(_ text: String) { copied.append(text) }
    }

    static func model(
        platform: RecordingPlatform = RecordingPlatform(), hostCount: Int = 1,
        defaults: UserDefaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!,
        appStoreID: String = "6740000000", usageDisplay: UsageDisplaySetting = UsageDisplaySetting(),
        hitchRecorder: DiagnosticRecorder? = nil
    ) -> SettingsModel {
        SettingsModel(
            app: app, hostCount: { hostCount }, defaults: defaults,
            platform: platform, links: SettingsLinks(
                appStoreID: appStoreID,
                support: URL(string: "https://example.com/support")!,
                privacyPolicy: URL(string: "https://example.com/privacy")!
            ),
            usageDisplay: usageDisplay, hitchRecorder: hitchRecorder
        )
    }

    // MARK: - 捲動卡頓記錄

    static func hitchRecorder() -> DiagnosticRecorder {
        DiagnosticRecorder(
            sink: DiagnosticLogFile(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hitch-\(UUID().uuidString)")),
            defaults: UserDefaults(suiteName: "hitch-r-\(UUID().uuidString)")!, system: { HitchSystemState.sample })
    }

    @Test("卡頓記錄開關預設開啟,關掉時記錄器停止;沒有記錄器時不顯示區塊")
    func hitchToggleControlsRecorder() {
        let recorder = Self.hitchRecorder()
        let model = Self.model(hitchRecorder: recorder)
        #expect(model.hasHitchRecorder)
        #expect(model.recordsHitches)
        model.recordsHitches = false
        #expect(!recorder.isEnabled)
        #expect(!Self.model().hasHitchRecorder)
    }

    @Test("沒有記錄時分享回 nil 並標示為空;清除後不再標示")
    func hitchExportWhenEmpty() async {
        let model = Self.model(hitchRecorder: Self.hitchRecorder())
        let url = await model.exportHitchLog()
        #expect(url == nil)
        #expect(model.hitchLogIsEmpty)
        await model.clearHitchLog()
        #expect(!model.hitchLogIsEmpty)
    }

    // MARK: - 複製診斷資訊

    @Test("診斷資訊只有白名單欄位:app 版本、系統、裝置種類、主機數(不含 herdr 版本,#419)")
    func diagnosticsAreWhitelisted() {
        let platform = RecordingPlatform()
        let model = Self.model(platform: platform, hostCount: 2)

        model.copyDiagnostics()

        #expect(platform.copied == [
            """
            Purrdr 1.2.3 (45)
            System: iOS 26.1
            Device: iPhone
            Hosts: 2
            """,
        ])
        #expect(model.copiedDiagnostics)
    }

    // MARK: - 評分、連結

    @Test("「為 Purrdr 評分」打開 App Store 的撰寫評論頁")
    func rateOpensWriteReviewPage() {
        let platform = RecordingPlatform()
        let model = Self.model(platform: platform, appStoreID: "6740000000")

        model.rateApp()

        #expect(platform.opened == [URL(string: "https://apps.apple.com/app/id6740000000?action=write-review")!])
    }

    @Test("支援與隱私權政策經平台服務開啟")
    func linksOpenThroughPlatform() {
        let platform = RecordingPlatform()
        let model = Self.model(platform: platform)

        model.openSupport()
        model.openPrivacyPolicy()

        #expect(platform.opened == [URL(string: "https://example.com/support")!, URL(string: "https://example.com/privacy")!])
    }

    // MARK: - 偏好

    @Test("Return 送出預設開，改了存在輸入列讀的同一個 key")
    func returnSendsDefaultsOnAndPersists() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        let model = Self.model(defaults: defaults)
        #expect(model.returnSends)

        model.returnSends = false

        #expect(defaults.object(forKey: ComposerSettings.returnSendsKey) as? Bool == false)
        #expect(Self.model(defaults: defaults).returnSends == false)
    }

    @Test("觸覺回饋預設開，改了存在觸覺讀的同一個 key")
    func hapticsDefaultsOnAndPersists() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        let model = Self.model(defaults: defaults)
        #expect(model.hapticsEnabled)

        model.hapticsEnabled = false

        #expect(defaults.object(forKey: HapticSettings.enabledKey) as? Bool == false)
        #expect(Self.model(defaults: defaults).hapticsEnabled == false)
    }

    @Test("外觀預設自動，改了存在 app 根畫面讀的同一個 key")
    func appearanceDefaultsAutomaticAndPersists() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        let model = Self.model(defaults: defaults)
        #expect(model.appearance == .automatic)

        model.appearance = .dark

        #expect(defaults.string(forKey: AppearancePreference.storageKey) == "dark")
        #expect(Self.model(defaults: defaults).appearance == .dark)
    }

    @Test("用量顯示預設已用,改了存起來;既有偏好(剩餘)不受影響;方案用量畫面的 model 讀同一個 key(#420)")
    func planUsageDisplayDefaultsUsedAndPersists() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        let model = Self.model(defaults: defaults)
        #expect(model.planUsageDisplay == .used)

        model.planUsageDisplay = .remaining
        #expect(Self.model(defaults: defaults).planUsageDisplay == .remaining)

        model.planUsageDisplay = .used

        #expect(Self.model(defaults: defaults).planUsageDisplay == .used)
        let hostID = HostSelection.host(UUID())
        let usage = PlanUsageModel(
            hosts: [HostOption(id: hostID, name: "Mac")], fallback: hostID, store: InMemoryPlanUsageSelectionStore(),
            defaults: defaults
        ) { _, _ in nil }
        #expect(usage.display == .used)
    }

    @Test("方案用量畫面開著期間在設定改了用量顯示,下次出現就跟著變")
    func planUsageReadsDisplayAgainWhenAppearing() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        PlanUsageModel.Display.remaining.store(in: defaults)
        let hostID = HostSelection.host(UUID())
        let usage = PlanUsageModel(
            hosts: [HostOption(id: hostID, name: "Mac")], fallback: hostID, store: InMemoryPlanUsageSelectionStore(),
            defaults: defaults
        ) { _, _ in nil }
        #expect(usage.display == .remaining)

        Self.model(defaults: defaults).planUsageDisplay = .used
        usage.appeared()

        #expect(usage.display == .used)
        usage.disappeared()
    }

    @Test("設定 tab 改用量顯示,全 app 共用的用量顯示設定(用量區與 context)立即跟著變(#389)")
    func planUsageDisplayUpdatesSharedSetting() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        let shared = UsageDisplaySetting(defaults: defaults)
        let model = Self.model(defaults: defaults, usageDisplay: shared)
        #expect(shared.display == .used)
        model.planUsageDisplay = .remaining
        #expect(shared.display == .remaining)
    }

    @Test("版本字顯示 app 版本與 build")
    func versionText() {
        #expect(Self.model().appVersionText == "1.2.3 (45)")
    }
}
