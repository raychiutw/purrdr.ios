import Foundation

/// 聊天列表處理捲動指令的排程政策(#492 的 0.50.2 熱修意圖):
/// - app 不在前景時不排程、也不執行(背景不持續更新畫面);回前景後由呼叫端補一次事件排程。
/// - 排程後沒有指令時會重試幾次(等內容或量測到位);**重試額度只有事件(內容、使用者操作、鍵盤…)會補滿**,
///   版面(列表高度改變)只排一次處理、不補額度,所以高度反覆變動不會讓重試無限重設。純邏輯。
public struct ChatListFlushPolicy: Sendable, Equatable {
    public enum Reason: Sendable { case event, layout }

    public static let maximumRetries = 3

    public var isSceneActive = true
    public private(set) var retriesLeft = 0

    public init() {}

    /// 一次處理可以執行(前景)。
    public var mayRunFlush: Bool { isSceneActive }

    /// 要求排程一次處理;回傳要不要排。
    public mutating func schedule(_ reason: Reason) -> Bool {
        guard isSceneActive else { return false }
        if reason == .event { retriesLeft = Self.maximumRetries }
        return true
    }

    /// 這一次沒指令:還有額度就用掉一次並回傳 true(呼叫端再排一次重試)。
    public mutating func consumeRetry() -> Bool {
        guard isSceneActive, retriesLeft > 0 else { return false }
        retriesLeft -= 1
        return true
    }
}
