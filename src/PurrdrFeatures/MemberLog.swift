import Foundation
import PurrdrAgentFeatures
import PurrdrCore

/// 會員流程的診斷事件來源(#406、#688)。只給開發者看(Console.app、sysdiagnose)與診斷檔,不顯示在畫面上。
///
/// 篩選 `subsystem:com.raychiu.purrdr category:member`。只記結果碼:不含 email、權杖與會員 ID;
/// 後台回傳碼與原因等動態內容只在 Console(private),診斷檔只有固定代碼。
public enum MemberLog {
    public static func events(_ events: DiagnosticEvents) -> MemberDiagnostics {
        { event in events.record(diagnosticEvent(event)) }
    }

    public static func diagnosticEvent(_ event: MemberDiagnosticEvent) -> DiagnosticEvent {
        switch event {
        case .signedIn: .member(code: "sign_in_ok", detail: nil)
        case .refreshed: .member(code: "token_refresh_ok", detail: nil)
        case .refreshRejected(let code): .member(code: "token_refresh_rejected", detail: code)
        case .refreshUnavailable(let reason): .member(code: "token_refresh_unavailable", detail: reason)
        case .tokenStorageFailed: .member(code: "token_storage_failed", detail: nil)
        case .cleared: .member(code: "sign_in_cleared", detail: nil)
        }
    }

    /// 事件帶後台回傳碼或原因等動態內容時,Console 標 private。
    public static func isPrivate(_ event: MemberDiagnosticEvent) -> Bool {
        switch event {
        case .refreshRejected, .refreshUnavailable: true
        case .signedIn, .refreshed, .tokenStorageFailed, .cleared: false
        }
    }
}
