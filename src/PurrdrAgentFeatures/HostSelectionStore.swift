import Foundation

/// 選取中主機(行為規格 F1.3):新聊天開在它上面、它的 Agent 列表顯示在畫面上。
public enum HostSelection: Hashable, Sendable {
    case demo
    case host(UUID)

    /// 存放用的字串：`demo` 或主機 id。
    public var storedValue: String {
        switch self {
        case .demo: "demo"
        case .host(let id): id.uuidString
        }
    }

    public init?(storedValue: String) {
        if storedValue == "demo" {
            self = .demo
        } else if let id = UUID(uuidString: storedValue) {
            self = .host(id)
        } else {
            return nil
        }
    }
}

/// 選取中主機的本機存放處。選取要持久化，否則重新啟動後會選回第一台(或已刪除的主機,行為規格 F1.1)。
@MainActor
public protocol HostSelectionStore: AnyObject {
    func load() -> HostSelection?
    func save(_ selection: HostSelection)
}

/// 只在記憶體：測試與 UI 測試用。
@MainActor
public final class InMemoryHostSelectionStore: HostSelectionStore {
    private var selection: HostSelection?

    public init(_ selection: HostSelection? = nil) {
        self.selection = selection
    }

    public func load() -> HostSelection? { selection }
    public func save(_ selection: HostSelection) { self.selection = selection }
}

/// 存在 `UserDefaults`(只在這支裝置)。
@MainActor
public final class UserDefaultsHostSelectionStore: HostSelectionStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "selectedHost") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> HostSelection? { defaults.string(forKey: key).flatMap(HostSelection.init(storedValue:)) }
    public func save(_ selection: HostSelection) { defaults.set(selection.storedValue, forKey: key) }
}

/// 目前主機(所有主機或某一台)的本機存放處:`nil` 是所有主機。要持久化，重新啟動後仍是同一個範圍。
@MainActor
public protocol CurrentHostStore: AnyObject {
    func load() -> HostSelection?
    func save(_ host: HostSelection?)
}

/// 只在記憶體：測試與 UI 測試用。
@MainActor
public final class InMemoryCurrentHostStore: CurrentHostStore {
    private var host: HostSelection?

    public init(_ host: HostSelection? = nil) {
        self.host = host
    }

    public func load() -> HostSelection? { host }
    public func save(_ host: HostSelection?) { self.host = host }
}

/// 存在 `UserDefaults`(只在這支裝置)。
@MainActor
public final class UserDefaultsCurrentHostStore: CurrentHostStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "currentHost") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> HostSelection? { defaults.string(forKey: key).flatMap(HostSelection.init(storedValue:)) }

    public func save(_ host: HostSelection?) {
        if let host { defaults.set(host.storedValue, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
