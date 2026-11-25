import Foundation
import PurrdrCore

/// 測試等非同步副作用(背景 task、串流、actor 之間的往返)時的安全上限。
///
/// 等待都是「條件一成立就往下走」,所以這個值只影響失敗時多久才報;給得寬，
/// 機器很忙(平行跑多份測試、load average 數十)時才不會在條件成立前就逾時。
///
/// #493:CI runner 整輪 swift test 跑 13 分鐘以上時，單次等待曾超過 30 秒而偶發 CancellationError(前例 #153、#324)。
/// 這些測試的流程不依賴實際時間(sleep 都是注入的)，所以逾時只代表 runner 被卡住;放寬到 120 秒。
public let asyncWaitLimit: Duration = .seconds(120)

/// 去抖用的假 sleep:等待一直卡住，直到 `open()`(去抖時間到)或所在的 task 被取消;`open()` 之後的等待立刻結束。
/// `requested` 記下每次要求的時間,`completed` 記下沒被取消、真的等滿的次數(用來斷言「只有最後一次去抖等滿」)。
public actor DebounceGate {
    public private(set) var requested: [Duration] = []
    /// 等滿(沒被取消)的次數。
    public private(set) var completed = 0
    private var isOpen = false
    private var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextID = 0

    public init() {}

    /// 給被測物注入的 closure。
    public nonisolated var sleep: Sleep {
        { duration in try await self.wait(duration) }
    }

    /// 去抖時間到：還在等的(沒被取消的)全部醒來，之後的等待也立刻結束。
    public func open() {
        isOpen = true
        let resumed = waiting
        waiting = [:]
        resumed.values.forEach { $0.resume() }
    }

    private func wait(_ duration: Duration) async throws {
        requested.append(duration)
        defer { if !Task.isCancelled { completed += 1 } }
        guard !isOpen else { return try Task.checkCancellation() }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                register(continuation, id: id)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// 已經被取消就不等(取消處理可能比登記先跑)。
    private func register(_ continuation: CheckedContinuation<Void, any Error>, id: Int) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            waiting[id] = continuation
        }
    }

    private func cancel(_ id: Int) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
