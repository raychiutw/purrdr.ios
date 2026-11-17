import Foundation

/// 等待一段時間：期限與輪詢間隔的計時。正式程式用 `Sleeping.task`,測試注入假時鐘(例如 `RecordingSleeper.sleep`)。
public typealias Sleep = @Sendable (Duration) async throws -> Void

/// 正式程式的等待。
public enum Sleeping {
    /// 以 `Task.sleep` 真的等待(取消時丟 `CancellationError`)。
    public static let task: Sleep = { try await Task.sleep(for: $0) }
}
