import Foundation

/// 一次性主機指令的期限，依指令性質設定(行為規格「每個指令 20 秒」為預設)。
public enum HostCommandDeadline {
    /// 預設：每個指令 20 秒。
    public static let standard: Duration = .seconds(20)
    /// 探測(主機作業系統):指令很短，卡住要盡早發現。
    public static let probe: Duration = .seconds(10)
    /// 主機要連網下載的 herdr 指令(`herdr update`、`herdr plugin install`;不是有自我時限的主機腳本)。
    public static let download: Duration = .seconds(300)
    /// 讀取期限的上限：比主機腳本的自我時限(`HostScriptTimeLimit.readSeconds`,120 秒)短，app 先逾時、主機只收尾。
    public static let maximumRead: Duration = .seconds(100)

    /// 輸出可能很大的讀取：20 秒加上以 32 KiB/s 估算 `bytes` 的傳輸時間(同圖片上傳),最多 `maximumRead`。
    public static func transfer(bytes: Int) -> Duration {
        min(standard + .milliseconds(bytes / 32), maximumRead)
    }
}

/// 一次性主機指令在期限內沒有結束。通道已經關閉，可以重試。
public enum HostCommandError: Error, Equatable {
    case deadlineExceeded
}

extension HostChannel {
    /// 一次性主機指令的唯一入口：執行 `command`,交給 `body` 讀輸出，`deadline` 從通道開好起算(撥號有自己的期限)。
    ///
    /// 期限到丟 `HostCommandError.deadlineExceeded`、外層取消丟 `CancellationError`:兩者都不等 `body` 或開通道配合，
    /// 立刻返回並關閉通道(晚到的通道一到就關)。長時間的串流(事件訂閱、Pane 終端機)不經這裡。
    func runOnce<Value: Sendable>(
        _ command: String, deadline: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void,
        _ body: @escaping @Sendable (any ExecSession) async throws -> Value
    ) async throws -> Value {
        let race = CommandRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.begin(continuation) else { return }
                race.track(Task {
                    let session: any ExecSession
                    do {
                        session = try await execute(command)
                    } catch {
                        await race.finish(.failure(error))
                        return
                    }
                    guard race.attach(session) else {
                        await session.close()
                        return
                    }
                    race.track(Task {
                        guard (try? await sleep(deadline)) != nil, !Task.isCancelled else { return }
                        await race.abandon(throwing: HostCommandError.deadlineExceeded)
                    })
                    do {
                        await race.finish(.success(try await body(HostTimeLimitedSession(session))))
                    } catch {
                        await race.finish(.failure(error))
                    }
                })
            }
        } onCancel: {
            Task { await race.abandon(throwing: CancellationError()) }
        }
    }

    /// 執行一般指令(先送 EOF),在期限內收齊輸出。非零 exit 是結果不是例外(行為規格 §3.2)。
    func collect(
        _ command: String, deadline: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws -> CommandResult {
        try await runOnce(command, deadline: deadline, sleep: sleep) { session in
            await session.closeStdin()
            var result = CommandResult()
            for try await event in session.output {
                switch event {
                case .stdout(let data): result.stdout.append(data)
                case .stderr(let data): result.stderr.append(data)
                case .exit(let code, _): result.exitCode = code
                }
            }
            return result
        }
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

/// `runOnce` 的結果只交出一次：指令結束、期限到或外層取消，先到的勝出，其餘的工作取消、通道關閉。
private final class CommandRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var session: (any ExecSession)?
    private var tasks: [Task<Void, Never>] = []
    /// 在 `begin` 之前就結束(已經取消)時的結果。
    private var early: Result<Value, any Error>?
    private var isFinished = false

    /// 記下 continuation;已經結束時直接交出結果並回傳 `false`。
    func begin(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        let early: Result<Value, any Error>? = lock.withLock {
            guard isFinished else {
                self.continuation = continuation
                return nil
            }
            return self.early ?? .failure(CancellationError())
        }
        guard let early else { return true }
        continuation.resume(with: early)
        return false
    }

    func track(_ task: Task<Void, Never>) {
        let finished = lock.withLock {
            if !isFinished { tasks.append(task) }
            return isFinished
        }
        if finished { task.cancel() }
    }

    /// 通道開好了;已經結束時回傳 `false`(呼叫端自己關閉它)。
    func attach(_ session: any ExecSession) -> Bool {
        lock.withLock {
            guard !isFinished else { return false }
            self.session = session
            return true
        }
    }

    /// 指令自己結束：關閉通道後交出結果。
    func finish(_ result: Result<Value, any Error>) async {
        guard let claimed = claim(result) else { return }
        await claimed.session?.close()
        claimed.continuation?.resume(with: result)
    }

    /// 期限到或外層取消：立刻交出錯誤，通道在背景關閉(關閉可能要等主機回應)。
    func abandon(throwing error: any Error) async {
        guard let claimed = claim(.failure(error)) else { return }
        claimed.continuation?.resume(throwing: error)
        await claimed.session?.close()
    }

    private func claim(_ result: Result<Value, any Error>) -> (continuation: CheckedContinuation<Value, any Error>?, session: (any ExecSession)?)? {
        let claimed: (CheckedContinuation<Value, any Error>?, (any ExecSession)?, [Task<Void, Never>])? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            if continuation == nil { early = result }
            defer {
                continuation = nil
                session = nil
                tasks = []
            }
            return (continuation, session, tasks)
        }
        guard let claimed else { return nil }
        claimed.2.forEach { $0.cancel() }
        return (claimed.0, claimed.1)
    }
}
