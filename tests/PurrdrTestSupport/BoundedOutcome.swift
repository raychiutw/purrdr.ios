import Foundation

/// 在 `limit` 內等 `operation` 結束;沒結束就取消它並回傳 `nil`(卡住時以斷言失敗呈現，不讓測試掛住)。
///
/// 上限預設 `asyncWaitLimit`:平行跑的其他測試會以同步等待佔住執行緒。
public func boundedOutcome<Value: Sendable>(
    within limit: Duration = asyncWaitLimit, _ operation: @escaping @Sendable () async throws -> Value
) async -> Result<Value, any Error>? {
    let box = OutcomeBox<Value>()
    let task = Task {
        do {
            await box.set(.success(try await operation()))
        } catch {
            await box.set(.failure(error))
        }
    }
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if let result = await box.result { return result }
        try? await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    return nil
}

private actor OutcomeBox<Value: Sendable> {
    var result: Result<Value, any Error>?
    func set(_ result: Result<Value, any Error>) { self.result = result }
}
