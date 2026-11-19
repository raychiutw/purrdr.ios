import Foundation

/// 主機服務的更新提示(#198):HTTPS 主機回報的主機服務版本比這版 app 已知的最新版舊時，在主機清單提示更新。
///
/// 最新版是 app 內的常數(不連網路查 GitHub),發行新的主機服務時與 `host-service/service/Cargo.toml` 一起遞增
/// (`HostServiceUpdateTests` 核對兩邊一致)。使用者關閉某台主機的提示後，同一個新版本不再提示。
@MainActor
public struct HostServiceUpdates {
    /// 這版 app 已知的最新主機服務版本。
    nonisolated public static let latestKnownVersion = "0.3.0"

    /// 在主機上更新(或安裝)主機服務的一行指令：macOS、Linux。
    nonisolated public static let posixInstallCommand =
        "curl -fsSL https://github.com/raychiutw/purrdr.ios/releases/latest/download/install.sh | sh"
    /// Windows(PowerShell)。
    nonisolated public static let windowsInstallCommand =
        "irm https://github.com/raychiutw/purrdr.ios/releases/latest/download/install.ps1 | iex"

    public let latestVersion: String
    let store: any HostServiceUpdateStore

    public init(latestVersion: String = Self.latestKnownVersion, store: any HostServiceUpdateStore) {
        self.latestVersion = latestVersion
        self.store = store
    }

    /// 回報 `installed` 的主機要提示更新到的版本;不用提示(已是最新、比 app 知道的新、看不懂的版本)時 `nil`。
    func offeredVersion(installed: String) -> String? {
        guard let installed = Self.numbers(installed), let latest = Self.numbers(latestVersion) else { return nil }
        return installed.lexicographicallyPrecedes(latest) ? latestVersion : nil
    }

    /// `1.2.3` → `[1, 2, 3]`(缺的段補 0,所以 `1.2` 與 `1.2.0` 相同);預發行標記(`-beta`)之後不比。
    private static func numbers(_ version: String) -> [Int]? {
        let core = version.split(separator: "-", maxSplits: 1).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap(\.self) + Array(repeating: 0, count: 3 - parts.count)
    }
}

/// 使用者關閉了哪台主機的哪個版本的更新提示(只存在這支裝置，不同步)。
@MainActor
public protocol HostServiceUpdateStore: AnyObject {
    func dismissedVersions() -> [UUID: String]
    /// `nil` 移除(刪除主機時)。
    func setDismissedVersion(_ version: String?, for host: UUID)
}

/// 只在記憶體：測試與 UI 測試用。
@MainActor
public final class InMemoryHostServiceUpdateStore: HostServiceUpdateStore {
    private var versions: [UUID: String] = [:]

    public init() {}

    public func dismissedVersions() -> [UUID: String] { versions }
    public func setDismissedVersion(_ version: String?, for host: UUID) { versions[host] = version }
}

/// 存在 `UserDefaults`。
@MainActor
public final class UserDefaultsHostServiceUpdateStore: HostServiceUpdateStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "hostServiceUpdateDismissals") {
        self.defaults = defaults
        self.key = key
    }

    public func dismissedVersions() -> [UUID: String] {
        let stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    public func setDismissedVersion(_ version: String?, for host: UUID) {
        var stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        stored[host.uuidString] = version
        defaults.set(stored, forKey: key)
    }
}
