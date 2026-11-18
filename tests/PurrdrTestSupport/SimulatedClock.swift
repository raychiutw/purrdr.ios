import Foundation
import PurrdrCore

/// 模擬時間的 sleep:注入給被測物的等待都登記在這裡，`advance(to:)` 時到期的才結束。不真的等。
///
/// 用來在幾秒內跑完「一小時」的情境(流量守門，#168)。被取消的等待照常丟 `CancellationError`。
public actor SimulatedClock {
    /// 從開始到現在的模擬時間。
    public private(set) var elapsed: Duration = .zero
    /// 登記過的等待總數(每次 sleep 加一;判斷被測物是否還在動)。
    public private(set) var sleepCount = 0

    private var waiters: [UUID: (deadline: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
    /// 取消比登記先到的等待。
    private var cancelledEarly: Set<UUID> = []

    /// 模擬時間的起點(`now` 的 0 秒)。
    public static let start = Date(timeIntervalSince1970: 1_794_614_400)

    private nonisolated let elapsedMirror = ElapsedMirror()

    public init() {}

    /// 給被測物注入的 closure。
    public nonisolated var sleep: Sleep {
        { duration in try await self.wait(duration) }
    }

    /// 模擬時間的現在(`start` + 經過時間),給同步讀時間的被測物(例如 `ConversationClock`)。
    public nonisolated var now: @Sendable () -> Date {
        { [elapsedMirror] in Self.start.addingTimeInterval(elapsedMirror.seconds) }
    }

    /// 還沒到期的等待中，最早的到期時間。
    public var nextDeadline: Duration? { waiters.values.map(\.deadline).min() }

    /// 把時間推到 `target`,結束所有到期的等待。
    public func advance(to target: Duration) {
        elapsed = max(elapsed, target)
        let components = elapsed.components
        elapsedMirror.seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let due = waiters.filter { $0.value.deadline <= elapsed }
        for (id, waiter) in due {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    private func wait(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        sleepCount += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledEarly.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = (elapsed + duration, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            cancelledEarly.insert(id)
            return
        }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// `SimulatedClock.elapsed` 的同步副本(秒)。
private final class ElapsedMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSeconds: TimeInterval = 0

    var seconds: TimeInterval {
        get { lock.withLock { storedSeconds } }
        set { lock.withLock { storedSeconds = newValue } }
    }
}
