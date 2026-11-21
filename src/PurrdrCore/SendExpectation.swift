import Crypto
import Foundation

/// 送出前要主機比對的對象(#304、raychiutw/purrdr.host#29):app 看到的 Agent session 與畫面。
///
/// 主機服務(0.7.0 起，`HostServiceFeature.sendExpectations`)在送出前比對，不符就不送、回 `pane_changed`
/// (`HostServiceError.paneChanged`)。SSH 主機沒有這一步：herdr 請求不帶這些欄位，對象由送出前重讀的 snapshot 確認。
public struct SendExpectation: Sendable, Equatable {
    /// herdr 回報的 `agent_session` 值(`Agent.sessionID`)。
    public var session: String?
    /// 畫面指紋(`fingerprint(ofScreen:)`);回答選擇題時帶上，確認還是看到的那一題。
    public var screen: String?

    public init(session: String? = nil, screen: String? = nil) {
        self.session = session
        self.screen = screen
    }

    /// 什麼都不比對。
    public static let none = SendExpectation()

    public var isEmpty: Bool { session == nil && screen == nil }

    /// 畫面指紋：可見畫面文字(`source: visible`、`format: text`)UTF-8 bytes 的 SHA-256,小寫 hex。與主機服務同一個定義。
    public static func fingerprint(ofScreen text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
