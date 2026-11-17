import Foundation
import PurrdrCore

/// 一條 SSH 連線為什麼結束(#133 診斷)。
public enum SSHDropReason: Sendable, Equatable {
    /// keepalive 送出後期限內沒有回應：視為半開連線，app 關掉它。
    case keepaliveTimeout
    /// 開 channel(含等 exec／pty-req 回覆)逾時：視為半開連線，app 關掉整條(行為規格 §7.2)。
    case channelOpenTimeout
    /// app 要求關閉(`disconnect()`:網路切換、喚醒探測失敗、編輯主機…;是誰要求的由呼叫端另外記錄)。
    case disconnectRequested
    /// socket 層錯誤(連線被重設、網路不通…),附上錯誤描述(只給開發者看)。
    case networkError(String)
    /// 對端關閉(主機結束連線，或 TCP 被關掉而沒有錯誤)。
    case closedByPeer
}

/// 連線生命週期的事件。`dial` 是這個主機通道的撥號序號(從 1 起算)。
public enum SSHConnectionEvent: Sendable, Equatable {
    /// 撥號、握手、登入都完成。
    case connected(dial: Int)
    /// 撥號失敗(不會快取，下一個指令重撥)。
    case dialFailed(dial: Int, error: SSHConnectionError)
    /// 連線結束，附上原因與壽命(從登入完成算起)。
    case dropped(dial: Int, reason: SSHDropReason, lifetime: Duration)
}

/// 接收連線診斷事件。可能從 event loop 或 actor 呼叫，實作要能在任何執行緒執行、不可阻塞。
/// 可攜核心不 import `os`,由 Features 以 `os.Logger` 實作後注入(AGENTS.md 可攜核心規則)。
public typealias SSHConnectionDiagnostics = @Sendable (SSHConnectionEvent) -> Void
