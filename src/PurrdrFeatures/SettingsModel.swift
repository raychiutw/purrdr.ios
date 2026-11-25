import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 平台服務(Seam 3):開外部網址、剪貼簿。iOS 實作是 `SystemPlatformServices`,測試用記錄呼叫的假實作。
@MainActor
public protocol PlatformServices: AnyObject {
    /// 用系統開啟網址(App Store、Safari)。
    func open(_ url: URL)
    func copy(_ text: String)
}

/// 這支 app 與裝置的資訊，由 composition root 從 Bundle 與系統讀出。
///
/// `device` 只放裝置種類(「iPhone」「iPad」),**不可**放使用者取的裝置名稱(常含本名)。
public struct AppInfo: Sendable, Equatable {
    public var version: String
    public var build: String
    /// 例如「iOS 26.1」。
    public var system: String
    public var device: String

    public init(version: String, build: String, system: String, device: String) {
        self.version = version
        self.build = build
        self.system = system
        self.device = device
    }
}

/// 設定頁的外部連結。App Store id 上架時才取得，目前是 composition root 的佔位常數。
public struct SettingsLinks: Sendable, Equatable {
    public var appStoreID: String
    public var support: URL
    public var privacyPolicy: URL

    public init(appStoreID: String, support: URL, privacyPolicy: URL) {
        self.appStoreID = appStoreID
        self.support = support
        self.privacyPolicy = privacyPolicy
    }

    /// App Store 的撰寫評論頁(#37 故事 46)。
    public var writeReview: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "apps.apple.com"
        components.path = "/app/id\(appStoreID)"
        components.queryItems = [URLQueryItem(name: "action", value: "write-review")]
        return components.url!
    }
}

/// 設定頁的 model(行為規格 F15,範圍依 #32):版本、複製診斷資訊、評分、支援與隱私權連結、
/// Return 送出偏好、外觀(#246)。
@MainActor
@Observable
public final class SettingsModel {
    /// 剛複製過診斷資訊(畫面把按鈕改成「已拷貝」)。
    public private(set) var copiedDiagnostics = false

    /// 接實體鍵盤時 Return 是否送出(預設開;關掉時 Return 換行、Command-Return 送出)。#2 故事 50。
    /// 存在輸入列(`ComposerBar` 的 `@AppStorage`)讀的同一個 key。
    public var returnSends: Bool {
        didSet { defaults.set(returnSends, forKey: ComposerSettings.returnSendsKey) }
    }

    /// 觸覺回饋(預設開;#14 回答 Agent 時的觸覺)。存在 `HapticSettings.enabledKey`,跟 `SystemHaptics` 讀同一個 key。
    public var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: HapticSettings.enabledKey) }
    }

    /// 外觀(#246;預設自動)。存在 `AppearancePreference.storageKey`,app 根畫面以 `@AppStorage` 讀同一個 key 立即套用。
    public var appearance: AppearancePreference {
        didSet { appearance.store(in: defaults) }
    }

    /// 方案用量顯示已用或剩餘(#393;全域偏好,預設剩餘)。存在 `PlanUsageModel.Display.storageKey`,方案用量畫面出現時讀。
    public var planUsageDisplay: PlanUsageModel.Display {
        didSet {
            planUsageDisplay.store(in: defaults)
            usageDisplay.display = planUsageDisplay
        }
    }

    /// 送出可撤回的秒數(#300;預設 3、0–10,0 為關閉)。存在 `UndoSendSettings.secondsKey`,下一則送出就生效。
    public var undoSendSeconds: Int {
        didSet {
            let clamped = UndoSendSettings.clamped(undoSendSeconds)
            if clamped != undoSendSeconds { undoSendSeconds = clamped }
            defaults.set(clamped, forKey: UndoSendSettings.secondsKey)
        }
    }

    /// 記錄捲動卡頓(診斷;預設開、只記數字不含對話內容、只存在這支手機,由使用者自己分享)。沒有記錄器時(例如測試)為 false。
    public var recordsHitches: Bool {
        didSet { hitchRecorder?.isEnabled = recordsHitches }
    }

    /// 分享按鈕按下後沒有記錄可分享(畫面顯示一行說明)。
    public private(set) var hitchLogIsEmpty = false

    /// 用量區與 context 讀的全 app 共用設定(#389);設定 tab 改了(`planUsageDisplay`)同步過去。
    public let usageDisplay: UsageDisplaySetting

    private let app: AppInfo
    private let hostCount: @MainActor () -> Int
    private let defaults: UserDefaults
    private let platform: any PlatformServices
    private let links: SettingsLinks
    private let hitchRecorder: DiagnosticRecorder?

    public init(
        app: AppInfo, hostCount: @escaping @MainActor () -> Int, defaults: UserDefaults,
        platform: any PlatformServices, links: SettingsLinks, usageDisplay: UsageDisplaySetting = UsageDisplaySetting(),
        hitchRecorder: DiagnosticRecorder? = nil
    ) {
        self.hitchRecorder = hitchRecorder
        recordsHitches = hitchRecorder?.isEnabled ?? false
        self.usageDisplay = usageDisplay
        self.app = app
        self.hostCount = hostCount
        self.defaults = defaults
        self.platform = platform
        self.links = links
        returnSends = defaults.object(forKey: ComposerSettings.returnSendsKey) as? Bool ?? true
        hapticsEnabled = HapticSettings.isEnabled(defaults)
        appearance = AppearancePreference.stored(in: defaults)
        planUsageDisplay = PlanUsageModel.Display.stored(in: defaults)
        undoSendSeconds = UndoSendSettings.seconds(in: defaults)
    }

    public var appVersionText: String { "\(app.version) (\(app.build))" }

    // MARK: - 診斷資訊

    /// 複製診斷資訊。內容是**白名單**:只有下列欄位，逐一由型別化的值組成;
    /// 絕不含主機名、位址、使用者名稱或對話內容(#2 故事 115)。
    public func copyDiagnostics() {
        platform.copy(diagnostics)
        copiedDiagnostics = true
    }

    /// 診斷資訊是給開發者看的，固定英文、不翻譯。
    var diagnostics: String {
        [
            "Purrdr \(appVersionText)",
            "System: \(app.system)",
            "Device: \(app.device)",
            "Hosts: \(hostCount())",
        ].joined(separator: "\n")
    }

    // MARK: - 卡頓記錄

    public var hasHitchRecorder: Bool { hitchRecorder != nil }

    /// 準備可分享的記錄檔;還沒有任何記錄時回 nil。
    public func exportHitchLog() async -> URL? {
        let url = await hitchRecorder?.exportFile()
        hitchLogIsEmpty = url == nil
        return url
    }

    public func clearHitchLog() async {
        await hitchRecorder?.clear()
        hitchLogIsEmpty = false
    }

    // MARK: - 連結

    public func rateApp() { platform.open(links.writeReview) }
    public func openSupport() { platform.open(links.support) }
    public func openPrivacyPolicy() { platform.open(links.privacyPolicy) }
}
