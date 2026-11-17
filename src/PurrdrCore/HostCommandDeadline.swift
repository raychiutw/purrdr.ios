import Foundation

/// 一次性主機操作的期限，依性質設定(行為規格「每個指令 20 秒」為預設)。可攜：每種連線方式共用。
public enum HostCommandDeadline {
    /// 預設：每個指令 20 秒。
    public static let standard: Duration = .seconds(20)
    /// 探測(主機作業系統):指令很短，卡住要盡早發現。
    public static let probe: Duration = .seconds(10)
    /// 主機要連網下載的 herdr 指令(`herdr update`、`herdr plugin install`;不是有自我時限的主機腳本)。
    public static let download: Duration = .seconds(300)
    /// 讀取期限的上限：比主機腳本的自我時限(`HostScriptTimeLimit.readSeconds`,120 秒)短，app 先逾時、主機只收尾。
    public static let maximumRead: Duration = .seconds(100)

    /// 輸出可能很大的讀取：20 秒加上以 32 KiB/s 估算 `bytes` 的傳輸時間，最多 `maximumRead`。
    public static func transfer(bytes: Int) -> Duration {
        min(upload(bytes: bytes), maximumRead)
    }

    /// 上傳：20 秒加上以 32 KiB/s 估算的傳輸時間(行為規格 F7)。不封頂：主機上傳腳本的自我時限也隨大小加長。
    public static func upload(bytes: Int) -> Duration {
        standard + .milliseconds(bytes / 32)
    }

    /// 一次性主機操作的唯一計時入口：`open` 開好資源(通道、連線)後交給 `body`,結束就 `close`。
    ///
    /// `deadline` 預設從開好起算(開通道有自己的期限);`includesOpening` 時連開通道一起算(喚醒探測)。
    /// 期限到丟 `HostCommandError.deadlineExceeded`、外層取消丟 `CancellationError`:兩者都不等 `open` 或 `body` 配合，
    /// 立刻返回，資源在背景關閉(晚到的資源一到就關)。
    public static func run<Resource: Sendable, Value: Sendable>(
        _ deadline: Duration, includesOpening: Bool = false, sleep: @escaping Sleep,
        open: @escaping @Sendable () async throws -> Resource,
        close: @escaping @Sendable (Resource) async -> Void,
        body: @escaping @Sendable (Resource) async throws -> Value
    ) async throws -> Value {
        let race = DeadlineRace<Resource, Value>(close: close)
        let startTimer: @Sendable () -> Void = {
            race.track(Task {
                guard (try? await sleep(deadline)) != nil, !Task.isCancelled else { return }
                await race.abandon(throwing: HostCommandError.deadlineExceeded)
            })
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.begin(continuation) else { return }
                if includesOpening { startTimer() }
                race.track(Task {
                    let resource: Resource
                    do {
                        resource = try await open()
                    } catch {
                        await race.finish(.failure(error))
                        return
                    }
                    guard race.attach(resource) else {
                        await close(resource)
                        return
                    }
                    if !includesOpening { startTimer() }
                    do {
                        await race.finish(.success(try await body(resource)))
                    } catch {
                        await race.finish(.failure(error))
                    }
                })
            }
        } onCancel: {
            Task { await race.abandon(throwing: CancellationError()) }
        }
    }
}

/// 一次性主機操作在期限內沒有結束(主機可能已經執行)。資源已經關閉，可以重試。
///
/// 各功能的錯誤(`HerdrError`、`ImageUploadError`、`HostFolderError`)把它包成自己的 `deadlineExceeded`。
public enum HostCommandError: Error, Equatable {
    case deadlineExceeded
}

/// `HostCommandDeadline.run` 的結果只交出一次：操作結束、期限到或外層取消，先到的勝出，其餘的工作取消、資源關閉。
private final class DeadlineRace<Resource: Sendable, Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let close: @Sendable (Resource) async -> Void
    private var continuation: CheckedContinuation<Value, any Error>?
    private var resource: Resource?
    private var tasks: [Task<Void, Never>] = []
    /// 在 `begin` 之前就結束(已經取消)時的結果。
    private var early: Result<Value, any Error>?
    private var isFinished = false

    init(close: @escaping @Sendable (Resource) async -> Void) {
        self.close = close
    }

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

    /// 資源開好了;已經結束時回傳 `false`(呼叫端自己關閉它)。
    func attach(_ resource: Resource) -> Bool {
        lock.withLock {
            guard !isFinished else { return false }
            self.resource = resource
            return true
        }
    }

    /// 操作自己結束：關閉資源後交出結果。
    func finish(_ result: Result<Value, any Error>) async {
        guard let claimed = claim(result) else { return }
        if let resource = claimed.resource { await close(resource) }
        claimed.continuation?.resume(with: result)
    }

    /// 期限到或外層取消：立刻交出錯誤，資源在背景關閉(關閉可能要等主機回應)。
    func abandon(throwing error: any Error) async {
        guard let claimed = claim(.failure(error)) else { return }
        claimed.continuation?.resume(throwing: error)
        if let resource = claimed.resource { await close(resource) }
    }

    private func claim(_ result: Result<Value, any Error>) -> (continuation: CheckedContinuation<Value, any Error>?, resource: Resource?)? {
        let claimed: (CheckedContinuation<Value, any Error>?, Resource?, [Task<Void, Never>])? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            if continuation == nil { early = result }
            defer {
                continuation = nil
                resource = nil
                tasks = []
            }
            return (continuation, resource, tasks)
        }
        guard let claimed else { return nil }
        claimed.2.forEach { $0.cancel() }
        return (claimed.0, claimed.1)
    }
}
