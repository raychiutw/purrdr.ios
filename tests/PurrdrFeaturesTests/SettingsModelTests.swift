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
    static let bridge = HerdrCommand.bridge()
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
        host: FakeHost? = FakeHost(), platform: RecordingPlatform = RecordingPlatform(), hostCount: Int = 1,
        defaults: UserDefaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!,
        appStoreID: String = "6740000000", usageDisplay: UsageDisplaySetting = UsageDisplaySetting()
    ) -> SettingsModel {
        SettingsModel(
            app: app, client: { host.map { HerdrClient(channel: $0) } }, hostCount: { hostCount }, defaults: defaults,
            platform: platform, links: SettingsLinks(
                appStoreID: appStoreID,
                support: URL(string: "https://example.com/support")!,
                privacyPolicy: URL(string: "https://example.com/privacy")!
            ),
            usageDisplay: usageDisplay
        )
    }

    // MARK: - 主機 herdr 版本

    @Test("主機 herdr 版本取自 snapshot")
    func herdrVersionComesFromSnapshot() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        let model = Self.model(host: host)

        await model.load()

        #expect(model.herdrVersion == .reported("0.9.5"))
    }

    @Test("沒有主機時顯示無主機，不送任何指令")
    func noHostMeansNoHerdrVersion() async {
        let model = Self.model(host: nil)

        await model.load()

        #expect(model.herdrVersion == .noHost)
    }

    @Test("讀不到 snapshot 時顯示讀不到")
    func unreachableHostMeansUnavailable() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: FakeReply(stdout: Data(), stderr: Data("sh: herdr: command not found\n".utf8), exitCode: 127))
        let model = Self.model(host: host)

        await model.load()

        #expect(model.herdrVersion == .unavailable)
    }

    // MARK: - 複製診斷資訊

    @Test("診斷資訊只有白名單欄位:app 版本、系統、裝置種類、主機數、herdr 版本")
    func diagnosticsAreWhitelisted() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        let platform = RecordingPlatform()
        let model = Self.model(host: host, platform: platform, hostCount: 2)
        await model.load()

        model.copyDiagnostics()

        #expect(platform.copied == [
            """
            Purrdr 1.2.3 (45)
            System: iOS 26.1
            Device: iPhone
            Hosts: 2
            herdr: 0.9.5
            """,
        ])
        #expect(model.copiedDiagnostics)
    }

    @Test("診斷資訊不含 snapshot 裡的任何個人資料(workspace 名稱、路徑、使用者、標題)")
    func diagnosticsNeverIncludeHostData() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        let platform = RecordingPlatform()
        let model = Self.model(host: host, platform: platform)
        await model.load()

        model.copyDiagnostics()

        let text = try #require(platform.copied.first)
        for personal in ["garden-journal", "scratch", "/Users", "demo", "term_", "w1:", "claude"] {
            #expect(!text.contains(personal), "診斷資訊含有「\(personal)」")
        }
    }

    @Test("主機回報的版本若不像版本號(可能夾帶路徑、主機名、使用者),不放進診斷資訊")
    func diagnosticsDropSuspiciousVersion() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") { response in
            // 改動：snapshot 的 version 換成夾帶使用者與主機名的字串。
            var result = response["result"] as! [String: Any]
            var snapshot = result["snapshot"] as! [String: Any]
            snapshot["version"] = "0.9.5 someone@studio-mac:/Users/someone"
            result["snapshot"] = snapshot
            response["result"] = result
        })
        let platform = RecordingPlatform()
        let model = Self.model(host: host, platform: platform)
        await model.load()

        model.copyDiagnostics()

        let text = try #require(platform.copied.first)
        #expect(!text.contains("someone"))
        #expect(text.hasSuffix("herdr: unrecognized"))
    }

    @Test("沒有主機時診斷資訊的 herdr 欄位是 none")
    func diagnosticsWithoutHost() async throws {
        let platform = RecordingPlatform()
        let model = Self.model(host: nil, platform: platform, hostCount: 0)
        await model.load()

        model.copyDiagnostics()

        let text = try #require(platform.copied.first)
        #expect(text.hasSuffix("Hosts: 0\nherdr: none"))
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

    @Test("每次讀版本都用當下選取的主機(換主機後重讀)")
    func herdrVersionFollowsSelectedHost() async {
        let first = FakeHost()
        await first.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        let second = FakeHost()
        await second.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") { response in
            // 改動：第二台主機回報較新的版本。
            var result = response["result"] as! [String: Any]
            var snapshot = result["snapshot"] as! [String: Any]
            snapshot["version"] = "0.9.6"
            result["snapshot"] = snapshot
            response["result"] = result
        })
        var current = HerdrClient(channel: first)
        let model = SettingsModel(
            app: Self.app, client: { current }, hostCount: { 2 },
            defaults: UserDefaults(suiteName: "settings-\(UUID().uuidString)")!, platform: RecordingPlatform(),
            links: SettingsLinks(appStoreID: "1", support: URL(string: "https://example.com")!, privacyPolicy: URL(string: "https://example.com")!)
        )
        await model.load()
        #expect(model.herdrVersion == .reported("0.9.5"))

        current = HerdrClient(channel: second)
        await model.load()

        #expect(model.herdrVersion == .reported("0.9.6"))
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
