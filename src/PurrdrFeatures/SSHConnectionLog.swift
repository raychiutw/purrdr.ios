import Foundation
import os
import PurrdrSSH

/// SSH 連線診斷事件的系統紀錄(#133)。只給開發者看(Console.app、sysdiagnose),不顯示在畫面上。
///
/// 實機上收集:Mac 的 Console.app 選 iPhone,篩選 `subsystem:com.raychiu.purrdr category:ssh`
/// (網路切換與喚醒探測丟棄連線在 category `hosts`)。
public enum SSHConnectionLog {
    /// 以 `os.Logger` 記錄某台主機通道的事件。主機位址標成 private(Console 預設遮住),事件內容是 public。
    public static func system(host: String) -> SSHConnectionDiagnostics {
        let logger = Logger(subsystem: "com.raychiu.purrdr", category: "ssh")
        return { event in
            let message = message(for: event)
            switch event {
            case .connected: logger.notice("\(host, privacy: .private): \(message, privacy: .public)")
            case .dialFailed, .dropped: logger.error("\(host, privacy: .private): \(message, privacy: .public)")
            }
        }
    }

    public static func message(for event: SSHConnectionEvent) -> String {
        switch event {
        case .connected(let dial):
            "dial \(dial) connected"
        case .dialFailed(let dial, let error):
            "dial \(dial) failed: \(error)"
        case .dropped(let dial, let reason, let lifetime):
            "dial \(dial) dropped after \(lifetime.components.seconds)s: \(describe(reason))"
        }
    }

    private static func describe(_ reason: SSHDropReason) -> String {
        switch reason {
        case .keepaliveTimeout: "keepalive timeout"
        case .channelOpenTimeout: "channel open timeout"
        case .disconnectRequested: "disconnect requested by the app"
        case .networkError(let description): "network error: \(description)"
        case .closedByPeer: "closed by the host or the network"
        }
    }
}
