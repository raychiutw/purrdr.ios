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

/// 設定頁的 model(行為規格 F15,範圍依 #32):版本、主機 herdr 版本、複製診斷資訊、評分、支援與隱私權連結、
/// Return 送出偏好、外觀(#246)。
@MainActor
@Observable
public final class SettingsModel {
    public enum HerdrVersion: Equatable, Sendable {
        /// 沒有可用的主機。
        case noHost
        case loading
        case reported(String)
        /// 問不到主機，或主機沒回報。
        case unavailable
    }

    public private(set) var herdrVersion: HerdrVersion
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

    /// 送出可撤回的秒數(#300;預設 3、0–10,0 為關閉)。存在 `UndoSendSettings.secondsKey`,下一則送出就生效。
    public var undoSendSeconds: Int {
        didSet {
            let clamped = UndoSendSettings.clamped(undoSendSeconds)
            if clamped != undoSendSeconds { undoSendSeconds = clamped }
            defaults.set(clamped, forKey: UndoSendSettings.secondsKey)
        }
    }

    private let app: AppInfo
    /// 目前選取主機的 client(沒有主機時 `nil`)。每次讀版本都重新取，換主機後重開設定就是新主機。
    private let client: @MainActor () -> HerdrClient?
    private let hostCount: @MainActor () -> Int
    private let defaults: UserDefaults
    private let platform: any PlatformServices
    private let links: SettingsLinks

    public init(
        app: AppInfo, client: @escaping @MainActor () -> HerdrClient?, hostCount: @escaping @MainActor () -> Int, defaults: UserDefaults,
        platform: any PlatformServices, links: SettingsLinks
    ) {
        self.app = app
        self.client = client
        self.hostCount = hostCount
        self.defaults = defaults
        self.platform = platform
        self.links = links
        herdrVersion = .loading
        returnSends = defaults.object(forKey: ComposerSettings.returnSendsKey) as? Bool ?? true
        hapticsEnabled = HapticSettings.isEnabled(defaults)
        appearance = AppearancePreference.stored(in: defaults)
        undoSendSeconds = UndoSendSettings.seconds(in: defaults)
    }

    public var appVersionText: String { "\(app.version) (\(app.build))" }

    /// 讀主機回報的 herdr 版本(snapshot 的 `version`,即執行中伺服器的版本)。
    public func load() async {
        guard let client = client() else {
            herdrVersion = .noHost
            return
        }
        do {
            herdrVersion = .reported(try await client.snapshot().version)
        } catch {
            herdrVersion = .unavailable
        }
    }

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
            "herdr: \(diagnosticHerdrVersion)",
        ].joined(separator: "\n")
    }

    private var diagnosticHerdrVersion: String {
        switch herdrVersion {
        case .noHost: "none"
        case .loading, .unavailable: "unknown"
        case .reported(let version): Self.isPlainVersion(version) ? version : "unrecognized"
        }
    }

    /// 主機回報的字串只在「看起來就是版本號」時才放進診斷資訊，避免夾帶路徑、主機名或使用者。
    static func isPlainVersion(_ version: String) -> Bool {
        !version.isEmpty && version.count <= 32
            && version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }
            && version.first!.isNumber
    }

    // MARK: - 連結

    public func rateApp() { platform.open(links.writeReview) }
    public func openSupport() { platform.open(links.support) }
    public func openPrivacyPolicy() { platform.open(links.privacyPolicy) }
}
