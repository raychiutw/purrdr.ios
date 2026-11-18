import Foundation

/// 終端機輸入元件的輸入入口(診斷紀錄的事件名稱)。
public enum TerminalInputCall: String, Sendable, CaseIterable {
    case setMarkedText, unmarkText, insertText, deleteBackward, replace
    case becomeFirstResponder, resignFirstResponder, cancelComposition
    case keyBarKey, paste
}

/// 終端機輸入的診斷紀錄(尚未實作)。
public enum TerminalInputTrace {
    public static func line(
        _ call: TerminalInputCall, text: String? = nil, selectedRange: NSRange,
        markedBefore: String, markedAfter: String, sent: [TerminalRemoteInput]
    ) -> String {
        ""
    }

    public static func characterClasses(_ text: String) -> String {
        ""
    }
}
