import Foundation
import PurrdrAgentFeatures
import PurrdrHTTPS

/// HTTPS 連線事件(#689)轉成診斷事件的來源,與 `SSHConnectionLog` 同樣分兩個出口:
/// 系統 Console(category `https`;固定文字 public、主機位址與動態內容 private)與可分享的診斷檔(只有代碼與主機匿名序號)。
public enum HTTPSConnectionLog {
    /// 某台 HTTPS 主機連線的診斷觀察者。`host` 是主機服務位址:只有 Console 以 private 記。
    public static func events(_ events: DiagnosticEvents, host: String) -> HTTPSConnectionDiagnostics {
        { event in events.record(diagnosticEvent(event, host: host)) }
    }

    public static func diagnosticEvent(_ event: HTTPSConnectionEvent, host: String) -> DiagnosticEvent {
        switch event {
        case .connected(let dial):
            return .connected(host: host, dial: dial, transport: .https)
        case .dialFailed(let dial, let error, let elapsed):
            return .dialFailed(host: host, dial: dial, error: error, detail: "after \(elapsed.components.seconds)s", transport: .https)
        case .dropped(let dial, let reason, let lifetime):
            let seconds = Int(lifetime.components.seconds)
            let code: DiagnosticDropReason
            var detail: String?
            switch reason {
            case .heartbeatTimeout: code = .heartbeatTimeout
            case .tokenRejected: code = .tokenRejected
            case .disconnectRequested: code = .disconnectRequested
            case .networkError(let description): (code, detail) = (.networkError, description)
            case .closedByPeer: code = .closedByPeer
            }
            return .dropped(host: host, dial: dial, reason: code, lifetimeSeconds: seconds, detail: detail, transport: .https)
        }
    }
}
