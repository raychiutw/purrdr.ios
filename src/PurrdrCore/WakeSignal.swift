import Synchronization

/// 可叫醒的等待：`wait(atMost:)` 等到時間到或被 `wake()` 叫醒。沒有人在等時的 `wake()` 留給下一次等待(不會漏掉)。
public final class WakeSignal: Sendable {
    private struct State {
        var isWakePending = false
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextWaiterID: UInt64 = 0
    }

    private let state = Mutex(State())
    private let sleep: Sleep

    /// - Parameter sleep: `wait(atMost:)` 的計時(測試注入)。
    public init(sleep: @escaping Sleep = Sleeping.task) {
        self.sleep = sleep
    }

    /// 有人在等。
    public var isWaiting: Bool { state.withLock { !$0.waiters.isEmpty } }

    /// 叫醒所有在等的;沒有人在等時，下一次等待直接結束。
    public func wake() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.waiters.isEmpty else {
                state.isWakePending = true
                return []
            }
            let waiting = Array(state.waiters.values)
            state.waiters = [:]
            return waiting
        }
        for waiter in waiters { waiter.resume() }
    }

    /// 等到被叫醒，或 `limit` 到(`nil` 不限時)。取消或 `sleep` 失敗時丟出。
    public func wait(atMost limit: Duration?) async throws {
        let hasPendingWake = state.withLock { state in
            defer { state.isWakePending = false }
            return state.isWakePending
        }
        if hasPendingWake { return }
        if let limit {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.sleep(limit) }
                group.addTask { await self.waitForWake() }
                defer { group.cancelAll() }
                try await group.next()
            }
        } else {
            await waitForWake()
        }
        try Task.checkCancellation()
    }

    private func waitForWake() async {
        let waiterID = state.withLock { state in
            defer { state.nextWaiterID += 1 }
            return state.nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumesNow = state.withLock { state in
                    if Task.isCancelled || state.isWakePending {
                        state.isWakePending = false
                        return true
                    }
                    state.waiters[waiterID] = continuation
                    return false
                }
                if resumesNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: waiterID) }?.resume()
        }
    }
}
