import Foundation
import Observation

/// 各自記住上次選的電腦的主機工具。
public enum HostPickerScope: String, CaseIterable, Sendable {
    case loginShell
    case files
}

/// 主機工具上次選的電腦的本機存放處。
@MainActor
public protocol HostPickerStore: AnyObject {
    func load(_ scope: HostPickerScope) -> HostSelection?
    func save(_ host: HostSelection, for scope: HostPickerScope)
}

/// 只在記憶體：測試與 UI 測試用。
@MainActor
public final class InMemoryHostPickerStore: HostPickerStore {
    private var hosts: [HostPickerScope: HostSelection] = [:]

    public init() {}

    public func load(_ scope: HostPickerScope) -> HostSelection? { hosts[scope] }
    public func save(_ host: HostSelection, for scope: HostPickerScope) { hosts[scope] = host }
}

/// 存在 `UserDefaults`(只在這支裝置)。
@MainActor
public final class UserDefaultsHostPickerStore: HostPickerStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(_ scope: HostPickerScope) -> HostSelection? {
        defaults.string(forKey: Self.key(scope)).flatMap(HostSelection.init(storedValue:))
    }

    public func save(_ host: HostSelection, for scope: HostPickerScope) {
        defaults.set(host.storedValue, forKey: Self.key(scope))
    }

    private static func key(_ scope: HostPickerScope) -> String { "hostPicker.\(scope.rawValue)" }
}

/// 登入 Shell、檔案與新增聊天標題列的主機挑選鈕(#245):只換這個畫面用的電腦，不改選取中主機。
@MainActor
@Observable
public final class HostPickerModel {
    public let options: [HostOption]
    public private(set) var selection: HostSelection
    private let remember: (HostSelection) -> Void

    /// - Parameter preferred: 依序採用第一個在選項裡的;都不在時選第一個選項。
    public init(options: [HostOption], preferred: [HostSelection?], remember: @escaping (HostSelection) -> Void = { _ in }) {
        self.options = options
        let listed = Set(options.map(\.id))
        selection = preferred.compactMap { $0 }.first { listed.contains($0) } ?? options.first?.id ?? .demo
        self.remember = remember
    }

    /// 登入 Shell、檔案：預設上次選的電腦，沒選過或已不在選項裡時用選取中主機。
    public static func remembering(
        _ scope: HostPickerScope, options: [HostOption], fallback: HostSelection, store: any HostPickerStore
    ) -> HostPickerModel {
        HostPickerModel(options: options, preferred: [store.load(scope), fallback]) { store.save($0, for: scope) }
    }

    /// 新增聊天：預設聊天列表篩選的主機(`nil` 是所有主機)，所有主機時用選取中主機;不記住。
    public static func newChat(options: [HostOption], currentHost: HostSelection?, selection: HostSelection) -> HostPickerModel {
        HostPickerModel(options: options, preferred: [currentHost, selection])
    }

    public var selectedOption: HostOption? { options.first { $0.id == selection } }

    public func select(_ host: HostSelection) {
        guard host != selection, options.contains(where: { $0.id == host }) else { return }
        selection = host
        remember(host)
    }
}
