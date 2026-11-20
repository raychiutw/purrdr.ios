import Foundation
import PurrdrCore

/// 主機服務的更新提示(#198):HTTPS 主機回報的主機服務版本比這版 app 已知的最新版舊時，在主機清單提示更新。
///
/// 最新版是 app 內的常數(不連網路查 GitHub),發行新的主機服務(raychiutw/purrdr.host)時一起遞增，並跑
/// `scripts/sync-purrdr-host.sh` 更新 `vendor/purrdr-host/VERSION`(`HostServiceUpdateTests` 核對兩邊一致)。使用者關閉某台主機的提示後，同一個新版本不再提示。
@MainActor
public struct HostServiceUpdates {
    /// 這版 app 已知的最新主機服務版本。
    nonisolated public static let latestKnownVersion = "0.7.0"

    /// 在主機上更新(或安裝)主機服務的一行指令：macOS、Linux。
    nonisolated public static let posixInstallCommand =
        "curl -fsSL https://github.com/raychiutw/purrdr.host/releases/latest/download/install.sh | sh"
    /// Windows(PowerShell)。
    nonisolated public static let windowsInstallCommand =
        "irm https://github.com/raychiutw/purrdr.host/releases/latest/download/install.ps1 | iex"

    /// 主機服務能自己更新(`purrdr-host-service update`、自動更新)的第一個版本;更舊的要重跑一行安裝指令。
    nonisolated public static let selfUpdatingVersion = HostServiceVersion(0, 5, 0)

    /// 0.5.0 起在主機上立刻更新的指令：macOS、Linux(用安裝位置的完整路徑：0.6.0 以前的安裝與 `--no-path` 不在 PATH)。
    nonisolated public static let posixUpdateCommand = "~/.purrdr/host-service/bin/purrdr-host-service update"
    /// Windows(PowerShell)。
    nonisolated public static let windowsUpdateCommand =
        #"& "$HOME\.purrdr\host-service\bin\purrdr-host-service.exe" update"#

    /// 回報 `installed` 的主機要用的更新指令。
    nonisolated public static func commands(installed: String) -> HostServiceUpdateCommands {
        let canUpdateItself = HostServiceVersion(installed).map { $0 >= selfUpdatingVersion } ?? false
        return canUpdateItself
            ? HostServiceUpdateCommands(
                installedVersion: installed, canUpdateItself: true, posix: posixUpdateCommand, windows: windowsUpdateCommand)
            : HostServiceUpdateCommands(
                installedVersion: installed, canUpdateItself: false, posix: posixInstallCommand, windows: windowsInstallCommand)
    }

    public let latestVersion: String
    let store: any HostServiceUpdateStore

    public init(latestVersion: String = Self.latestKnownVersion, store: any HostServiceUpdateStore) {
        self.latestVersion = latestVersion
        self.store = store
    }

    /// 回報 `installed` 的主機要提示更新到的版本;不用提示(已是最新、比 app 知道的新、看不懂的版本)時 `nil`。
    func offeredVersion(installed: String) -> String? {
        guard let installed = HostServiceVersion(installed), let latest = HostServiceVersion(latestVersion) else { return nil }
        return installed < latest ? latestVersion : nil
    }
}

/// 更新一台主機的主機服務要執行的指令(依它已安裝的版本)。
public struct HostServiceUpdateCommands: Equatable, Sendable {
    public var installedVersion: String
    /// 0.5.0 起為 `true`:執行 `update`;更舊的版本沒有 `update`,指令是一行安裝指令。
    public var canUpdateItself: Bool
    public var posix: String
    public var windows: String

    public init(installedVersion: String, canUpdateItself: Bool, posix: String, windows: String) {
        self.installedVersion = installedVersion
        self.canUpdateItself = canUpdateItself
        self.posix = posix
        self.windows = windows
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
