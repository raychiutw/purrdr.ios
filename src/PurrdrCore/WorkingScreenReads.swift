import Foundation

/// 工作中讀 pane 畫面的節奏(#204):即時預覽與背景 agents 窗格不必每 2 秒讀一次，每 2 秒輪詢下約每 6 秒讀一次。
///
/// 只限制工作中;需要你、閒置等狀態一律放行，由各自的規則決定讀不讀(需要你的反應速度不變)。
/// `pane.wait_for_output` 只能等特定字串，取代不了讀畫面(polling-network-usage.md §4)。
public struct WorkingScreenReads: Sendable {
    /// 兩次讀取的最短間隔：比 6 秒少 1 秒，輪詢早到幾百毫秒仍是每 3 輪讀一次。
    public static let minimumGap: TimeInterval = 5

    private var lastReadAt: Date?
    private var wasWorking = false

    public init() {}

    /// 這一輪可不可以讀畫面;工作中放行時記下時間。剛進入工作中的第一輪一律放行。
    public mutating func allowsRead(isWorking: Bool, at now: Date) -> Bool {
        defer { wasWorking = isWorking }
        guard isWorking else { return true }
        if wasWorking, let lastReadAt, now.timeIntervalSince(lastReadAt) < Self.minimumGap { return false }
        lastReadAt = now
        return true
    }
}
