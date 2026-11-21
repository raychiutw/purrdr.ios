import Foundation

/// 「傳送測試通知」失敗的原因(#328):SSH 與主機服務(`push.test`,raychiutw/purrdr.host#60)共用，
/// 畫面文字在 Features 的 `PushModel.describeTestFailure`。
public enum PushTestError: Error, Equatable, Sendable {
    /// 這支裝置在那台主機沒有推播配對，或後台已不認得這組配對。
    case notPaired
    /// 後台回 `subscription_required`:沒有 Purrdr Plus。
    case subscriptionRequired
    /// 後台回 `rate_limited`:送得太頻繁。
    case rateLimited
    /// 後台或推播服務沒送成(`apns_failed`、`http <狀態碼>`、連線錯誤);附原文，只給診斷、不給使用者看。
    case deliveryFailed(String)
    /// 主機服務比 0.11.0 舊，還不能送測試通知。
    case hostServiceOutdated(installed: String)
    /// 唯讀裝置不能送。
    case readOnlyDevice
    /// 這種連線沒有這個功能。
    case unsupported

    /// 後台的錯誤碼(主機服務的 `push_send_failed` 訊息)對應成錯誤。
    public init(backendCode message: String) {
        switch message {
        case "subscription_required": self = .subscriptionRequired
        case "rate_limited": self = .rateLimited
        default: self = .deliveryFailed(message)
        }
    }
}

/// 測試通知標題用的電腦名稱:主機服務與後台都只收 1–64 個字、不含控制字元。
public enum PushTestHostName {
    public static let maximumLength = 64

    /// 去掉控制字元與頭尾空白、超過上限以 code point 截斷;清理後是空的回 `nil`。
    public static func sanitized(_ name: String?) -> String? {
        guard let name else { return nil }
        let scalars = name.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maximumLength)))
        return limited.isEmpty ? nil : limited
    }
}
