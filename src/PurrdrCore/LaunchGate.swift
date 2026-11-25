import Foundation
import Synchronization

/// 第一個 frame 之後才開的閘(#590):冷啟動時不必馬上做的磁碟寫入(流量存檔、主機名稱對應表)排在這裡,
/// 開閘前只登記、開閘時依序執行一次。開閘後 `run` 立刻執行。可從任何執行緒呼叫;開閘由 app 在第一個 frame 後呼叫。
public final class LaunchGate: Sendable {
    private struct State {
        var isOpen = false
        var waiting: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())

    public init(isOpen: Bool = false) { state.withLock { $0.isOpen = isOpen } }

    public var isOpen: Bool { state.withLock { $0.isOpen } }

    /// 開閘前登記、開閘時執行;已開閘就立刻執行。
    public func run(_ work: @escaping @Sendable () -> Void) {
        let runsNow = state.withLock { state -> Bool in
            if state.isOpen { return true }
            state.waiting.append(work)
            return false
        }
        if runsNow { work() }
    }

    /// 開閘並執行登記的工作(只有第一次有作用)。
    public func open() {
        let work = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.isOpen else { return [] }
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for item in work { item() }
    }
}
