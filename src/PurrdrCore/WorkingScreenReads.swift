import Foundation

/// 工作中讀 pane 畫面的節奏(#204):即時預覽與背景 agents 窗格不必每 2 秒讀一次。
public struct WorkingScreenReads: Sendable {
    public init() {}

    /// 這一輪可不可以讀畫面;可以就記下時間。
    public mutating func allowsRead(isWorking: Bool, at now: Date) -> Bool {
        true
    }
}
