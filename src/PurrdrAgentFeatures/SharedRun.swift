import Foundation

/// 讓多個畫面共用同一份長駐工作(例：Agent 列表的即時更新,#31)。
///
/// iPad 上同一份列表可以同時開在好幾個視窗;每個視窗的 `.task` 都呼叫 `attach()`,
/// 工作只在第一個視窗來看時開始，最後一個視窗離開(task 被取消)時才取消。
/// 否則每個視窗各跑一份迴圈：指令加倍，而且共用的退避狀態會互相覆蓋。
@MainActor
public final class SharedRun {
    /// 目前在看的畫面數。
    public private(set) var viewers = 0
    private let work: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(_ work: @escaping @MainActor () async -> Void) {
        self.work = work
    }

    /// 開始看：沒有人在跑就開始工作。一直等到呼叫端的 task 被取消才回傳。
    public func attach() async {
        viewers += 1
        if task == nil {
            let work = work
            task = Task { await work() }
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.release(id) }
        }
        viewers -= 1
        if viewers == 0 {
            task?.cancel()
            task = nil
        }
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
