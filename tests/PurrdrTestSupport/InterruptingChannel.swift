import Foundation
import PurrdrCore
import PurrdrSSH

/// 寫進 stdin 超過 `failAfter` bytes 時連線斷掉：寫入丟錯、底層通道關閉(主機上的腳本讀到提早結束的 stdin)。
public struct InterruptingChannel: HostChannel {
    public struct Dropped: Error {}

    let base: any HostChannel
    let failAfter: Int

    public init(base: any HostChannel, failAfter: Int) {
        self.base = base
        self.failAfter = failAfter
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        Session(base: try await base.execute(command), budget: Budget(remaining: failAfter))
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession { try await base.openPTY(request) }

    final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(remaining: Int) { self.remaining = remaining }
        /// 這次寫入能送出多少 bytes(之後全部失敗)。
        func take(_ count: Int) -> Int {
            lock.withLock {
                let allowed = min(count, remaining)
                remaining -= allowed
                return allowed
            }
        }
    }

    struct Session: ExecSession {
        let base: any ExecSession
        let budget: Budget

        var output: AsyncThrowingStream<ExecOutput, any Error> {
            // 斷線後讀輸出也失敗。
            AsyncThrowingStream { continuation in continuation.finish(throwing: Dropped()) }
        }

        func write(_ data: Data) async throws {
            let allowed = budget.take(data.count)
            if allowed > 0 { try await base.write(data.prefix(allowed)) }
            if allowed < data.count {
                await base.close()
                throw Dropped()
            }
        }

        func closeStdin() async { await base.closeStdin() }
        func close() async { await base.close() }
    }
}
