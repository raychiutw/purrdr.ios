import Foundation

/// 閱讀位置位移追蹤(驗收 #489 的除錯量測):記下一個基準列離可見頂端的距離,之後累計最大位移。純邏輯。
public struct ReadingDriftTracker: Sendable, Equatable {
    public private(set) var baselineRowID: String?
    public private(set) var maxDrift = 0.0
    private var baselineDistance = 0.0

    public init() {}

    /// 設定基準並清掉先前的最大位移。
    public mutating func setBaseline(rowID: String, distanceFromVisibleTop: Double) {
        baselineRowID = rowID
        baselineDistance = distanceFromVisibleTop
        maxDrift = 0
    }

    /// 基準列目前離可見頂端的距離;沒有基準時忽略。
    public mutating func observe(distanceFromVisibleTop: Double) {
        guard baselineRowID != nil else { return }
        maxDrift = max(maxDrift, abs(distanceFromVisibleTop - baselineDistance))
    }

    /// 清除基準(使用者開始捲動、跟隨最新時)。
    public mutating func clear() {
        baselineRowID = nil
        maxDrift = 0
    }
}
