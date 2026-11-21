import Foundation

/// 送出前要主機比對的對象(#304、raychiutw/purrdr.host#29):app 看到的 Agent session。
///
/// 主機服務(0.7.0 起，`HostServiceFeature.sendExpectations`)在送出前比對，不符就不送、回 `pane_changed`
/// (`HostServiceError.paneChanged`)。SSH 主機沒有這一步：herdr 請求不帶這個欄位，對象由送出前重讀的 snapshot 確認。
/// 不比對畫面：主機讀可見畫面不帶 `lines`，與 app 讀的行數不同時指紋必不相符。
public struct SendExpectation: Sendable, Equatable {
    /// herdr 回報的 `agent_session` 值(`Agent.sessionID`)。
    public var session: String?

    public init(session: String? = nil) {
        self.session = session
    }

    /// 什麼都不比對。
    public static let none = SendExpectation()

    public var isEmpty: Bool { session == nil }
}
