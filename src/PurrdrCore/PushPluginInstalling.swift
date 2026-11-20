import Foundation

/// 這支裝置在一台主機上的推播狀態(推播外掛安裝的「查狀態」)。
public struct PushPluginStatus: Sendable, Equatable {
    /// 在主機上執行安裝的使用者(確認對話框說明以誰安裝)。
    public var user: String
    /// 這支裝置在這台主機上已有推播配對。
    public var isPaired: Bool
    /// herdr 已安裝主機外掛(不論是誰裝的)。
    public var pluginInstalled: Bool
    /// 這台主機上其他裝置的推播配對數(不含這支)。
    public var otherPairedDevices: Int

    public init(user: String, isPaired: Bool, pluginInstalled: Bool, otherPairedDevices: Int = 0) {
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
}
