import Foundation
import PurrdrCore

extension HostChannel {
    /// 一次性主機指令的唯一入口：執行 `command`,交給 `body` 讀輸出(計時見 `HostCommandDeadline.run`)。
    ///
    /// 主機腳本的自我時限到了(exit 124,#92)也丟 `HostCommandError.deadlineExceeded`。
    /// 長時間的串流(事件訂閱、Pane 終端機)不經這裡。
    func runOnce<Value: Sendable>(
        _ command: String, deadline: Duration, includesOpening: Bool = false, sleep: @escaping Sleep,
        _ body: @escaping @Sendable (any ExecSession) async throws -> Value
    ) async throws -> Value {
        try await HostCommandDeadline.run(
            deadline, includesOpening: includesOpening, sleep: sleep,
            open: { try await self.execute(command) },
            close: { await $0.close() },
            body: { try await body(HostTimeLimitedSession($0)) }
        )
    }

    /// 執行一般指令(先送 EOF),在期限內收齊輸出。非零 exit 是結果不是例外(行為規格 §3.2)。
    func collect(_ command: String, deadline: Duration, sleep: @escaping Sleep) async throws -> CommandResult {
        try await runOnce(command, deadline: deadline, sleep: sleep) { session in
            await session.closeStdin()
            return try await session.read()
        }
    }
}

extension ExecSession {
    /// 讀輸出直到結束：stdout 累積後交給 `onStdout`(可取走處理過的部分;回傳 `true` 就不再讀),stderr 與結束狀態收齊。
    func read(onStdout: (inout Data) throws -> Bool = { _ in false }) async throws -> CommandResult {
        var result = CommandResult()
        for try await event in output {
            switch event {
            case .stdout(let data):
                result.stdout.append(data)
                if try onStdout(&result.stdout) { return result }
            case .stderr(let data):
                result.stderr.append(data)
            case .exit(let code, let signal) where !result.didExit:
                result.exitCode = code
                result.signal = signal
                result.didExit = true
            case .exit:
                // 只認第一個結束狀態。
                break
            }
        }
        return result
    }
}

/// 主機腳本的自我時限到了(exit 124,#92)也是逾時：輸出串流改丟 `HostCommandError.deadlineExceeded`。
private struct HostTimeLimitedSession: ExecSession {
    let base: any ExecSession
    let output: AsyncThrowingStream<ExecOutput, any Error>

    init(_ base: any ExecSession) {
        self.base = base
        let source = base.output
        output = AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    for try await event in source {
                        if case .exit(let code, nil) = event, code == Int32(HostScriptTimeLimit.exitCode) { throw HostCommandError.deadlineExceeded }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func write(_ data: Data) async throws { try await base.write(data) }
    func closeStdin() async { await base.closeStdin() }
    func close() async { await base.close() }
}
