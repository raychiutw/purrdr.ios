import NIOCore
import PurrdrSSH
import Synchronization

/// 手動推進的 SSH 期限時鐘：期限只在測試呼叫 `advance(by:)` 時才到，不受機器快慢影響。
final class ManualSSHClock: SSHDeadlineScheduler {
    private struct Entry {
        let id: Int
        let due: TimeAmount
        let eventLoop: any EventLoop
        let task: @Sendable () -> Void
    }

    private struct State {
        var now: TimeAmount = .zero
        var nextID = 0
        var entries: [Entry] = []
    }

    private let state = Mutex(State())

    /// 還沒到期也沒取消的期限數。
    var pendingCount: Int { state.withLock { $0.entries.count } }

    func schedule(in delay: TimeAmount, on eventLoop: any EventLoop, _ task: @escaping @Sendable () -> Void) -> SSHScheduledDeadline {
        let id = state.withLock { state in
            state.nextID += 1
            state.entries.append(Entry(id: state.nextID, due: state.now + delay, eventLoop: eventLoop, task: task))
            return state.nextID
        }
        return SSHScheduledDeadline { [weak self] in
            self?.state.withLock { $0.entries.removeAll { $0.id == id } }
        }
    }

    /// 時間往前推，依到期先後在各自的 event loop 上執行到期的工作，執行完才返回。
    func advance(by amount: TimeAmount) async {
        let due = state.withLock { state in
            state.now = state.now + amount
            let now = state.now
            let due = state.entries.filter { $0.due <= now }.sorted { $0.due < $1.due }
            state.entries.removeAll { $0.due <= now }
            return due
        }
        for entry in due {
            try? await entry.eventLoop.submit { entry.task() }.get()
        }
    }
}
