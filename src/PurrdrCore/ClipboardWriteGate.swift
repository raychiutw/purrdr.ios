import Foundation

/// 把文字寫進這支手機的剪貼簿(不經通用剪貼簿同步到其他裝置)。
public protocol LocalClipboardWriting {
    func write(_ text: String)
}

/// 主機經 OSC 52 要寫剪貼簿時的待確認狀態:使用者允許才寫,連續請求只留最新一筆(#578)。
public struct ClipboardWriteGate: Equatable, Sendable {
    private var pendingText: String?

    public init() {}

    public var hasPendingRequest: Bool { pendingText != nil }

    /// 合法 UTF-8 且非空才待確認;其他忽略,不蓋掉已待確認的。
    public mutating func receive(_ content: Data) {
        guard let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
        pendingText = text
    }

    public mutating func allow(into clipboard: some LocalClipboardWriting) {
        guard let text = pendingText else { return }
        pendingText = nil
        clipboard.write(text)
    }

    public mutating func deny() {
        pendingText = nil
    }
}
