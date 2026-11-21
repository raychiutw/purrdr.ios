import Foundation

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
