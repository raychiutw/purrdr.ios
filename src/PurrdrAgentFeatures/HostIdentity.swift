import Foundation
import PurrdrCore

// 多主機合併列表(#39)的主機身分。pane id(`w1:p1`)與 session 在每台主機都可能重複，
// 所以列、聊天、釘選／靜音、草稿與對話快取的鍵一律帶主機身分(`HostSelection.storedValue`:主機 id,Demo 是 `demo`)。

/// 一個聊天在哪台主機的哪個 Pane。列表的導覽值、推播開聊天都用它。
public struct ChatRoute: Hashable, Sendable {
    public var host: HostSelection
    public var paneID: String

    public init(host: HostSelection, paneID: String) {
        self.host = host
        self.paneID = paneID
    }
}

// MARK: - 主機圖示

/// 主機圖示(#37 故事 5、#239):使用者替主機選的圖示，顯示在主機名稱前。11 種加「無」;`rawValue` 是存檔與同步的值，不可改。
public enum HostIcon: String, CaseIterable, Codable, Sendable {
    case desktop
    case laptop
    case macMini
    /// 機架(GLOSSARY 避免「Server」)。舊版存成 `server`,讀取時由 `init(stored:)` 換成它。
    case rack
    case pc
    case display
    /// 開發板(Raspberry Pi 之類)。
    case board
    /// 遊戲機。
    case console
    case home
    case cloud
    case terminal
    /// 「無」:名稱前留同寬空位。不叫 `none`,免得跟 `Optional.none` 混淆。
    case noIcon = "none"

    /// 沒選過圖示的主機。
    public static let `default`: HostIcon = .desktop

    /// 讀裝置上存的值;認得舊版的 `server`(現在是 `rack`)。不認得的值(較新版本加的)回 `nil`,由呼叫端用預設。
    public init?(stored: String) {
        self.init(rawValue: stored == "server" ? HostIcon.rack.rawValue : stored)
    }

    /// 主機名稱前的 SF Symbol;「無」是 `nil`。
    public var symbol: String? {
        switch self {
        case .desktop: "desktopcomputer"
        case .laptop: "laptopcomputer"
        case .macMini: "macmini"
        case .rack: "server.rack"
        case .pc: "pc"
        case .display: "display"
        case .board: "cpu"
        case .console: "gamecontroller"
        case .home: "house"
        case .cloud: "cloud"
        case .terminal: "apple.terminal"
        case .noIcon: nil
        }
    }

    /// 圖示選擇器(編輯器格子、選單)上的符號;「無」也要有一個可點的符號。
    public var pickerSymbol: String { symbol ?? "circle.slash" }

    /// 選擇器上的名稱。
    public var title: String {
        switch self {
        case .desktop: String(localized: "Desktop")
        case .laptop: String(localized: "Laptop")
        case .macMini: String(localized: "Mac mini")
        case .rack: String(localized: "Rack")
        case .pc: String(localized: "PC")
        case .display: String(localized: "Display")
        case .board: String(localized: "Dev Board")
        case .console: String(localized: "Game Console")
        case .home: String(localized: "House")
        case .cloud: String(localized: "Cloud")
        case .terminal: String(localized: "Terminal")
        case .noIcon: String(localized: "None")
        }
    }
}

/// 主機圖示的本機存放處(以主機 id 為鍵)。
@MainActor
public protocol HostIconStore: AnyObject {
    func icon(for host: UUID) -> HostIcon?
    /// `nil` 移除(刪除主機時)。
    func setIcon(_ icon: HostIcon?, for host: UUID)
}

/// 只在記憶體：測試與 UI 測試用。
@MainActor
public final class InMemoryHostIconStore: HostIconStore {
    private var icons: [UUID: HostIcon]

    public init(_ icons: [UUID: HostIcon] = [:]) {
        self.icons = icons
    }

    public func icon(for host: UUID) -> HostIcon? { icons[host] }
    public func setIcon(_ icon: HostIcon?, for host: UUID) { icons[host] = icon }
}

/// 存在 `UserDefaults`(主機同步開啟時由 `HostSyncModel` 另外上傳，#243)。
@MainActor
public final class UserDefaultsHostIconStore: HostIconStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "hostIcons") {
        self.defaults = defaults
        self.key = key
    }

    public func icon(for host: UUID) -> HostIcon? {
        stored[host.uuidString].flatMap(HostIcon.init(stored:))
    }

    public func setIcon(_ icon: HostIcon?, for host: UUID) {
        var icons = stored
        icons[host.uuidString] = icon?.rawValue
        defaults.set(icons, forKey: key)
    }

    private var stored: [String: String] { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
}

/// 列表上標示「這列是哪台主機」的名稱與圖示(只在非選取中主機的列)。
public struct HostLabel: Equatable, Sendable {
    public var name: String
    public var icon: HostIcon

    public init(name: String, icon: HostIcon) {
        self.name = name
        self.icon = icon
    }
}

/// 選單裡的一台主機：主機挑選鈕、聊天列表主機篩選與方案用量共用。
public struct HostOption: Identifiable, Equatable, Sendable {
    public var id: HostSelection
    public var name: String
    public var icon: HostIcon

    public init(id: HostSelection, name: String, icon: HostIcon = .default) {
        self.id = id
        self.name = name
        self.icon = icon
    }
}

// MARK: - 釘選、靜音(以主機分開)

/// 各主機的釘選、靜音存放處。同一個 session 值在不同主機是不同的聊天(路徑型的 session 在兩台主機可能完全相同)。
@MainActor
public protocol HostChatPreferencesStore: AnyObject {
    /// 某台主機的釘選、靜音。
    func store(for host: HostSelection) -> any ChatPreferencesStore
    /// 刪除主機時清掉它的偏好。
    func removeAll(for host: HostSelection)
}

/// 只在記憶體：測試與 UI 測試用(每次啟動都從空白開始)。
@MainActor
public final class InMemoryHostChatPreferencesStore: HostChatPreferencesStore {
    fileprivate var byHost: [String: ChatPreferences] = [:]

    public init() {}

    public func store(for host: HostSelection) -> any ChatPreferencesStore {
        ScopedChatPreferencesStore(scope: host.storedValue) { [unowned self] in
            byHost[$0] ?? ChatPreferences()
        } save: { [unowned self] scope, preferences in
            byHost[scope] = preferences
        }
    }

    public func removeAll(for host: HostSelection) { byHost[host.storedValue] = nil }
}

/// 存在 `UserDefaults`,一個 key 存所有主機(`主機身分 → ChatPreferences`)。
///
/// 舊版(#39 之前)的 `chatPreferences` 沒有主機身分，無法判斷屬於哪台主機，第一次使用時**明確丟棄**:
/// 套到每台主機會讓路徑型 session 在別台誤中，套到選取中主機則可能是錯的那台。#39 時 app 還沒上架，只影響開發裝置。
@MainActor
public final class UserDefaultsHostChatPreferencesStore: HostChatPreferencesStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "chatPreferencesByHost", legacyKey: String = "chatPreferences") {
        self.defaults = defaults
        self.key = key
        defaults.removeObject(forKey: legacyKey)
    }

    public func store(for host: HostSelection) -> any ChatPreferencesStore {
        ScopedChatPreferencesStore(scope: host.storedValue) { [unowned self] in
            all[$0] ?? ChatPreferences()
        } save: { [unowned self] scope, preferences in
            var all = all
            all[scope] = preferences
            self.all = all
        }
    }

    public func removeAll(for host: HostSelection) {
        var all = all
        all[host.storedValue] = nil
        self.all = all
    }

    private var all: [String: ChatPreferences] {
        get {
            guard let data = defaults.data(forKey: key),
                  let all = try? JSONDecoder().decode([String: ChatPreferences].self, from: data) else { return [:] }
            return all
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

/// 一台主機的釘選、靜音(讀寫轉給所屬的多主機存放處)。
@MainActor
private final class ScopedChatPreferencesStore: ChatPreferencesStore {
    private let scope: String
    private let loader: (String) -> ChatPreferences
    private let saver: (String, ChatPreferences) -> Void

    init(scope: String, load: @escaping (String) -> ChatPreferences, save: @escaping (String, ChatPreferences) -> Void) {
        self.scope = scope
        loader = load
        saver = save
    }

    func load() -> ChatPreferences { loader(scope) }
    func save(_ preferences: ChatPreferences) { saver(scope, preferences) }
}

// MARK: - agent 種類圖示

/// 列左側的 agent 種類圖示(#37 故事 6)。SF Symbols 沒有各家商標，所以用形狀不同的通用符號;
/// 種類名稱本身在副標裡，圖示對 VoiceOver 隱藏。
public enum AgentKindSymbol {
    public static func name(for kind: String) -> String {
        switch AgentKindName.canonical(kind) {
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "grok": "bolt"
        case "agy": "arrow.up.forward.circle"
        case "gemini": "star"
        case "pi": "function"
        case "omp": "hexagon"
        case "opencode": "curlybraces"
        case "copilot": "airplane"
        case "cline": "line.diagonal"
        case "amp": "waveform"
        case "droid": "cpu"
        default: "terminal"
        }
    }
}
