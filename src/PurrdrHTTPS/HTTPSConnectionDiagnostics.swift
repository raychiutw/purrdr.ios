import Foundation
import PurrdrCore

/// 一條 HTTPS(WSS)連線為什麼結束(#689 診斷;與 SSH 的 `SSHDropReason` 對應)。
public enum HTTPSDropReason: Sendable, Equatable {
    /// 心跳 ping 在期限內沒有 pong,或送出卡住超過心跳逾時:視為半開連線。
    case heartbeatTimeout
    /// 主機服務拒絕裝置權杖(無效、已撤銷;4401 或 `device_token_*` 錯誤)。
    case tokenRejected
    /// app 要求關閉(`disconnect()`)。
    case disconnectRequested
    /// socket 層錯誤,附上錯誤描述(只給開發者看,Console 標 private)。
    case networkError(String)
    /// 對端關閉(主機結束連線)。
    case closedByPeer
}

/// 連線生命週期的事件。`dial` 是這台主機連線的撥號序號(從 1 起算)。
/// 事件串流的結束(`endStreams`、`events.ended`)只是訂閱結束、連線仍在,不算連線事件。
public enum HTTPSConnectionEvent: Sendable, Equatable {
    /// 撥號與 `hello` 握手都完成。
    case connected(dial: Int)
    /// 撥號或握手失敗。`error` 只是錯誤種類名稱(不含關聯值)。`elapsed` 是撥號花的時間。
    case dialFailed(dial: Int, error: String, elapsed: Duration)
    /// 連線結束,附上原因與壽命(從握手完成算起)。
    case dropped(dial: Int, reason: HTTPSDropReason, lifetime: Duration)
}

/// 接收連線診斷事件。可能從任何執行緒呼叫,實作不可阻塞。
public typealias HTTPSConnectionDiagnostics = @Sendable (HTTPSConnectionEvent) -> Void

extension HTTPSConnectionEvent {
    /// 錯誤種類名稱:列舉 case 名稱(不含關聯值),其他錯誤只留型別名稱。
    static func kind(of error: any Error) -> String {
        if let error = error as? HostServiceError { return String(String(describing: error).prefix { $0 != "(" }) }
        if let error = error as? URLError { return "URLError.\(error.code.rawValue)" }
        return String(describing: type(of: error))
    }
}
