import Foundation

/// 從 app 管理主機服務(#290,raychiutw/purrdr.host#18):查更新狀態、立即更新、開關自動更新。HTTPS 主機才有。
public protocol HostServiceManaging: Sendable {
    /// `host_service.status`。
    func hostServiceUpdateStatus() async throws -> HostServiceUpdateStatus
    /// `host_service.update`:回應在主機服務重啟前送出。
    func updateHostService() async throws -> HostServiceUpdateStart
    /// `host_service.set_auto_update`,回傳改完後的開關。
    func setHostServiceAutoUpdate(_ enabled: Bool) async throws -> Bool
    /// 丟掉目前的連線、重新撥號握手，回傳 `welcome` 的主機服務版本(立即更新後確認結果用)。
    func reconnectForHostServiceVersion() async throws -> String?
}

/// 主機服務的更新狀態(`host_service.status.result`)。
public struct HostServiceUpdateStatus: Sendable, Equatable {
    public var installedVersion: String
    /// 取不到時是 `nil`,原因在 `latestError`。
    public var latestVersion: String?
    public var latestError: String?
    public var updateAvailable: Bool
    public var autoUpdate: Bool
    public var lastUpdate: HostServiceLastUpdate?
    /// 上次更新起不來、已換回舊版的版本。
    public var rolledBack: String?

    public init(
        installedVersion: String, latestVersion: String? = nil, latestError: String? = nil, updateAvailable: Bool, autoUpdate: Bool,
        lastUpdate: HostServiceLastUpdate? = nil, rolledBack: String? = nil
    ) {
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.latestError = latestError
        self.updateAvailable = updateAvailable
        self.autoUpdate = autoUpdate
        self.lastUpdate = lastUpdate
        self.rolledBack = rolledBack
    }
}

/// 上一次檢查或更新的時間與結果(結果是給人看的一句話，不解析)。
public struct HostServiceLastUpdate: Sendable, Equatable {
    /// RFC 3339 原文;讀不懂時 `checkedAt` 是 `nil`。
    public var checkedAtText: String
    public var result: String

    public init(checkedAtText: String, result: String) {
        self.checkedAtText = checkedAtText
        self.result = result
    }

    public var checkedAt: Date? { try? Date(checkedAtText, strategy: .iso8601) }
}

/// 立即更新的結果。
public enum HostServiceUpdateStart: Sendable, Equatable {
    /// 更新程序已啟動;主機服務接著重啟。
    case started(from: String, to: String)
    /// 已是最新，不重啟。
    case upToDate(version: String)
}

/// 主機服務管理專屬的錯誤。
public enum HostServiceManagementError: Error, Equatable, Sendable {
    /// 主機上跑的不是安裝好的主機服務(開發中直接執行),不能從 app 管理。
    case notInstalledCopy
    /// 已有更新在進行。
    case updateInProgress
    /// 取不到最新版本或啟動不了更新程序(主機服務的原文)。
    case updateFailed(String)
}
