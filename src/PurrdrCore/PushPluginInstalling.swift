import Foundation

/// 這支裝置在一台主機上的推播狀態(推播外掛安裝的「查狀態」)。
public struct PushPluginStatus: Sendable, Equatable {
    /// 在主機上執行安裝的使用者(確認對話框說明以誰安裝);主機服務不回報，是 `nil`(以執行主機服務的使用者安裝)。
    public var user: String?
    /// 這支裝置在這台主機上已有推播配對。
    public var isPaired: Bool
    /// herdr 已安裝主機外掛(不論是誰裝的)。
    public var pluginInstalled: Bool
    /// 這台主機上其他裝置的推播配對數(不含這支)。
    public var otherPairedDevices: Int

    public init(user: String?, isPaired: Bool, pluginInstalled: Bool, otherPairedDevices: Int = 0) {
        self.user = user
        self.isPaired = isPaired
        self.pluginInstalled = pluginInstalled
        self.otherPairedDevices = otherPairedDevices
    }
}

/// 推播外掛安裝失敗的原因(各實作共用)。
public enum PushPluginError: Error, Equatable {
    /// 安裝外掛失敗(主機沒有 git、連不上 GitHub、herdr 太舊…);附 herdr 的訊息。主機已回到配對前的樣子。
    case pluginInstallFailed(String)
    /// 移除外掛失敗;配對已移除，外掛還在(沒有配對時外掛什麼都不送)。
    case pluginUninstallFailed(String)
    /// 問 herdr 有沒有安裝外掛失敗(多半是 herdr 伺服器沒在跑)。
    case pluginListFailed(String)
    /// 主機上找不到這支裝置的配對檔。
    case notPaired
    /// 更新外掛失敗(#432;主機沒有 git、連不上 GitHub…);附 herdr 的訊息。外掛維持原版本。
    case pluginUpdateFailed(String)
    /// 主機服務比 0.6.0 舊，還不能代裝外掛;附主機回報的版本。
    case hostServiceOutdated(installed: String)
}

/// 推播外掛安裝(spec #261 的單一接縫):一個實例代表「一支裝置 × 一台主機」。
///
/// 實作：SSH(`SSHPushPluginInstaller`,`herdr plugin install`)、主機服務(HTTPS,`push.*` 協定訊息)、
/// 測試的 `FakePushPluginHost`。多裝置規則各實作一致：移除只刪這支裝置的配對，最後一支裝置移除時才移除 Purrdr 裝的外掛;
/// 外掛已裝時安裝只新增配對。
public protocol PushPluginInstalling: Sendable {
    /// 查狀態：不改動主機。
    func status() async throws -> PushPluginStatus
    /// 寫入這支裝置的推播配對，外掛還沒安裝就安裝。失敗時主機回到安裝前的樣子。
    func install(_ pairing: PushPairingFile) async throws
    /// 移除這支裝置的推播配對;沒有其他裝置的配對、且外掛是 Purrdr 裝的，一併移除外掛。
    func remove() async throws
    /// 改寫這支裝置配對的靜音清單，其餘內容不變;沒有配對丟 `PushPluginError.notPaired`。
    func updateMuted(_ muted: Set<String>) async throws
    /// 外掛已安裝、版本落後 `PushPluginRelease.latestKnownVersion` 時更新(#432);回傳是否執行了更新。
    /// 沒裝外掛不代裝;預設不做事(主機服務自己每輪更新，HTTPS 不需要)。失敗丟 `PushPluginError.pluginUpdateFailed`。
    func updatePluginIfNeeded() async throws -> Bool
}

extension PushPluginInstalling {
    public func updatePluginIfNeeded() async throws -> Bool { false }
}

/// app 認得的推播外掛版本(purrdr.host 0.16.0 發行的 0.3.0);外掛有新版時隨 app 遞增。
public enum PushPluginRelease {
    public static let latestKnownVersion = HostServiceVersion(0, 3, 0)
}

/// 「傳送測試通知」(#328)送出失敗的原因。SSH(app 經主機送)與 HTTPS(主機服務的 `push.test`)共用，畫面說明只對這個型別。
public enum PushTestNotificationError: Error, Equatable {
    /// 這支裝置在這台主機上沒有(有效的)推播配對:沒有配對檔、後台 404 `pairing_not_found` 或 410 `pairing_revoked`。
    case notPaired
    /// 後台 403 `subscription_required`:需要 Purrdr Plus。
    case subscriptionRequired
    /// 後台 429 `daily_limit_reached`:今天的測試通知次數用完了(#675;推播不再要 Plus，改以每日上限防濫用)。
    case dailyLimitReached
    /// 後台 429 `rate_limited`:每組配對每 60 秒 10 次(與狀態推播共用)。
    case rateLimited
    /// 後台 502 `apns_failed`:Apple 推播服務拒絕。
    case apnsFailed
    /// 主機沒有 `curl`。
    case curlMissing
    /// 主機連不上 Purrdr 後台;附 curl／PowerShell 的訊息。
    case backendUnreachable(String)
    /// 後台回了其他錯誤;附 HTTP 狀態碼。
    case backendRejected(statusCode: Int)
    /// 其他原因。
    case failed(String)

    /// 後台的錯誤碼(`error` 欄位)對應;不認得回 `nil`。
    public init?(errorCode: String) {
        switch errorCode {
        case "pairing_not_found", "pairing_revoked": self = .notPaired
        case "subscription_required": self = .subscriptionRequired
        case "rate_limited": self = .rateLimited
        case PushKind.dailyLimitReachedCode: self = .dailyLimitReached
        case "apns_failed": self = .apnsFailed
        default: return nil
        }
    }

    /// 後台的 HTTP 狀態碼對應(2xx 不是錯誤，呼叫端先判斷)。
    public init(statusCode: Int) {
        switch statusCode {
        case 403: self = .subscriptionRequired
        case 404, 410: self = .notPaired
        case 429: self = .rateLimited
        case 502: self = .apnsFailed
        default: self = .backendRejected(statusCode: statusCode)
        }
    }
}

/// 可能代裝推播外掛的主機連線(主機服務 0.6.0 起，#265)。
public protocol PushPluginInstallerProviding: Sendable {
    /// 依裝置 id 建立推播外掛安裝;這條連線不能代裝時是 `nil`。
    func pushPluginInstallers() -> (@Sendable (PushDeviceID) -> any PushPluginInstalling)?
}
