import Foundation
import os
import PurrdrCore

/// 會員流程的系統紀錄(#406)。只給開發者看(Console.app、sysdiagnose),不顯示在畫面上。
///
/// 篩選 `subsystem:com.raychiu.purrdr category:member`。只記結果碼:不含 email、權杖與會員 ID。
public enum MemberLog {
    public static let system: MemberDiagnostics = { event in
        let logger = Logger(subsystem: "com.raychiu.purrdr", category: "member")
        let message = message(for: event)
        switch event {
        case .signedIn, .refreshed, .cleared: logger.notice("\(message, privacy: .public)")
        case .tokenStorageFailed: logger.error("\(message, privacy: .public)")
        case .refreshRejected, .refreshUnavailable: logger.error("\(message, privacy: .private)")
        }
    }

    /// 事件帶後台回傳碼或原因等動態內容時,系統紀錄標 private。
    public static func isPrivate(_ event: MemberDiagnosticEvent) -> Bool {
        switch event {
        case .refreshRejected, .refreshUnavailable: true
        case .signedIn, .refreshed, .tokenStorageFailed, .cleared: false
        }
    }

    public static func message(for event: MemberDiagnosticEvent) -> String {
        switch event {
        case .signedIn: "sign-in ok"
        case .refreshed: "token refresh ok"
        case .refreshRejected(let code): "token refresh rejected: \(code)"
        case .refreshUnavailable(let reason): "token refresh unavailable (signed in kept): \(reason)"
        case .tokenStorageFailed: "token storage failed"
        case .cleared: "local sign-in cleared"
        }
    }
}
