import Foundation
import PurrdrAgentFeatures
import PurrdrSSH

/// SSH 連線事件(#133)轉成診斷事件(#688)的來源。事件進 `DiagnosticEvents` 後分兩個出口:
/// 系統 Console(固定文字 public、主機位址與錯誤描述 private)與可分享的診斷檔(只有代碼與主機匿名序號)。
///
/// 實機上收集:Mac 的 Console.app 選 iPhone,篩選 `subsystem:com.raychiu.purrdr category:ssh`
/// (網路切換與回前景決策在 category `hosts`)。
public enum SSHConnectionLog {
    /// 某台主機通道的診斷觀察者。`host` 是位址:只有 Console 以 private 記,診斷檔只寫匿名序號。
    /// 可能從 event loop 或 actor 呼叫(PurrdrSSH 已把 `dropped` 轉到背景佇列);`DiagnosticEvents.record` 本身只排程,不在呼叫端組字串或寫檔。
    public static func events(_ events: DiagnosticEvents, host: String) -> SSHConnectionDiagnostics {
        { event in events.record(diagnosticEvent(event, host: host)) }
    }

    public static func diagnosticEvent(_ event: SSHConnectionEvent, host: String) -> DiagnosticEvent {
        switch event {
        case .connected(let dial):
            return .connected(host: host, dial: dial)
        case .dialFailed(let dial, let error):
            return .dialFailed(host: host, dial: dial, error: caseName(of: error), detail: "\(error)")
        case .dropped(let dial, let reason, let lifetime):
            let seconds = Int(lifetime.components.seconds)
            switch reason {
            case .keepaliveTimeout:
                return .dropped(host: host, dial: dial, reason: .keepaliveTimeout, lifetimeSeconds: seconds, detail: nil)
            case .channelOpenTimeout:
                return .dropped(host: host, dial: dial, reason: .channelOpenTimeout, lifetimeSeconds: seconds, detail: nil)
            case .disconnectRequested:
                return .dropped(host: host, dial: dial, reason: .disconnectRequested, lifetimeSeconds: seconds, detail: nil)
            case .networkError(let description):
                return .dropped(host: host, dial: dial, reason: .networkError, lifetimeSeconds: seconds, detail: description)
            case .closedByPeer:
                return .dropped(host: host, dial: dial, reason: .closedByPeer, lifetimeSeconds: seconds, detail: nil)
            }
        }
    }

    /// 事件帶錯誤描述或原因等動態內容時,Console 標 private。
    public static func isPrivate(_ event: SSHConnectionEvent) -> Bool {
        switch event {
        case .connected: false
        case .dialFailed, .dropped: true
        }
    }

    public static func message(for event: SSHConnectionEvent) -> String {
        diagnosticEvent(event, host: "").consoleText
    }

    /// 列舉的 case 名稱(不含關聯值:例如 `hostKeyUnverified(presented:)` 的指紋不能進診斷檔)。
    private static func caseName(of error: Error) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }
}
