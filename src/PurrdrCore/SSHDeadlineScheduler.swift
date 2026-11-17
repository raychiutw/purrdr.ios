import NIOCore

/// 排定 SSH 期限(握手、check mode、開 channel)與 keepalive 的時鐘。正式程式用 event loop 的真實時間;測試注入可手動推進的時鐘。
public protocol SSHDeadlineScheduler: Sendable {
    /// `delay` 後在 `eventLoop` 上執行 `task`。
    func schedule(in delay: TimeAmount, on eventLoop: any EventLoop, _ task: @escaping @Sendable () -> Void) -> SSHScheduledDeadline
}

/// 排定好的期限。
public struct SSHScheduledDeadline: Sendable {
    private let cancelAction: @Sendable () -> Void

    /// - Parameter cancel: 取消這個期限(已執行或已取消時不做事)。
    public init(cancel: @escaping @Sendable () -> Void) {
        cancelAction = cancel
    }

    /// 取消，期限到了也不執行。
    public func cancel() {
        cancelAction()
    }
}

/// 以 event loop 的真實時間排定(預設)。
public struct EventLoopDeadlineScheduler: SSHDeadlineScheduler {
    /// 建立以真實時間排定的時鐘。
    public init() {}

    /// `delay` 後在 `eventLoop` 上執行 `task`。
    public func schedule(in delay: TimeAmount, on eventLoop: any EventLoop, _ task: @escaping @Sendable () -> Void)
        -> SSHScheduledDeadline
    {
        let scheduled = eventLoop.scheduleTask(in: delay, task)
        return SSHScheduledDeadline { scheduled.cancel() }
    }
}
