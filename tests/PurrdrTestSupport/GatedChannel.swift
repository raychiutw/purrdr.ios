import Foundation
import PurrdrCore
import PurrdrSSH

/// 開通道時先卡在一個不理會取消的閘門(像 NIO 的 future、死掉的連線),`open()` 之後才交給底層通道。
public actor GatedChannel: HostChannel {
    public let base: any HostChannel
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    public init(base: any HostChannel) {
        self.base = base
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        return try await base.execute(command)
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession { try await base.openPTY(request) }

    public func disconnect() async { await base.disconnect() }

    /// 打開閘門：卡住的與之後的開通道都交給底層通道。
    public func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    /// 等到有開通道卡在閘門上。
    public func waitUntilWaiting(timeout: Duration = asyncWaitLimit) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while waiting.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !waiting.isEmpty
    }
}
