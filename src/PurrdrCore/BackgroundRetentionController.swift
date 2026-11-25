import Foundation

/// 向系統要「進背景後多撐一下」的介面(#551;iOS 實作是 `UIApplication.beginBackgroundTask`)。
/// 核心只認這個介面,時鐘與剩餘背景時間都由實作提供,所以規則可以在 `swift test` 驗證。
@MainActor
public protocol BackgroundTaskScheduling: AnyObject {
    /// 申請一個 background task;`expiration` 是系統要收回時的回呼。回傳 `nil` 表示申請不到。
    func begin(expiration: @escaping @MainActor () -> Void) -> Int?
    func end(_ task: Int)
    /// 目前系統還給的背景時間(秒)。
    func remainingTime() -> TimeInterval
    /// 一段時間後呼叫 `fire`;回傳取消用的閉包。
    func schedule(after seconds: TimeInterval, fire: @escaping @MainActor () -> Void) -> () -> Void
}

/// 進背景時保留連線的規則(#551):所有視窗進背景、裝置沒鎖定才申請;
/// 保留時間取剩餘背景時間的 9 成、上限 `BackgroundRetention.duration`;
/// 回前景、時間到、expiry 都立刻結束。保留期間不做任何事(連線本身的 keepalive 照常,不輪詢、不寫狀態,#492)。
@MainActor
public final class BackgroundRetentionController {
    public static let remainingFraction = 0.9

    private let scheduler: BackgroundTaskScheduling
    private var task: Int?
    private var cancelTimer: (() -> Void)?

    public init(scheduler: BackgroundTaskScheduling) {
        self.scheduler = scheduler
    }

    public var isRetaining: Bool { task != nil }

    /// 保留時間:剩餘背景時間的 9 成,上限 25 秒;沒有剩餘時間就不保留。
    public static func retentionSeconds(remaining: TimeInterval) -> TimeInterval {
        max(0, min(remaining * remainingFraction, BackgroundRetention.duration))
    }

    /// 全部視窗都進背景了。
    public func didEnterBackground(isDeviceLocked: Bool) {
        guard task == nil, !isDeviceLocked else { return }
        guard let id = scheduler.begin(expiration: { [weak self] in self?.finish() }) else { return }
        let seconds = Self.retentionSeconds(remaining: scheduler.remainingTime())
        guard seconds > 0 else {
            scheduler.end(id)
            return
        }
        task = id
        cancelTimer = scheduler.schedule(after: seconds) { [weak self] in self?.finish() }
    }

    /// 回到前景。
    public func didBecomeActive() { finish() }

    private func finish() {
        cancelTimer?()
        cancelTimer = nil
        guard let id = task else { return }
        task = nil
        scheduler.end(id)
    }
}
