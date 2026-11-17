import Foundation

/// SSH 連到哪裡、以誰登入。
public struct SSHEndpoint: Sendable, Hashable, Codable {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}

/// SSH 連線層的錯誤。函式庫的內部錯誤字串不給使用者看(行為規格 §7.6),一律換成這裡的情況。
public enum SSHConnectionError: Error, Equatable, Sendable {
    /// 沒有 pin:主機出示了這個指紋，等使用者確認才登入(TOFU)。
    case hostKeyUnverified(presented: HostKeyFingerprint)
    /// 主機出示的 key 與已存的不同。可能重灌過，也可能有人攔截連線(行為規格 §8.2)。
    case hostKeyChanged(presented: HostKeyFingerprint, pinned: HostKeyFingerprint)
    /// 主機拒絕登入:Tailscale SSH 不放行這個使用者，或 OpenSSH 的金鑰／密碼不對。
    case authenticationFailed
    /// 主機不接受這種登入方式(例如沒開密碼登入、只開 keyboard-interactive)。祕密沒有送出。
    case authenticationMethodNotAccepted
    /// 主機拒絕連線:埠不對，或 SSH 沒開。
    case connectionRefused
    /// 找不到這個主機名稱。
    case hostNotFound
    /// 連線或握手逾時:主機睡著、不在 tailnet,或手機不在 tailnet。
    case timedOut
    /// 其他無法連上的情況。
    case unreachable
    /// 指令執行到一半連線斷了。主機可能已經執行，所以**不會自動重送**(行為規格 §7.3)。
    case connectionLost
    /// 連線健康，但主機拒絕開新的 channel 或拒絕 exec／pty 請求(例如 `MaxSessions`)。
    case channelRejected
    /// 使用者取消了 Tailscale SSH check mode 的等待。
    case tailscaleCheckCancelled
    /// 等 Tailscale SSH check mode 驗證等到期限(`SSHTimeouts.tailscaleCheck`)。
    case tailscaleCheckTimedOut
}
