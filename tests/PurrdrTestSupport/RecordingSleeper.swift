import Foundation

/// 記錄每次等待時間的 sleep(注入給 client 的期限、輪詢間隔)。
///
/// `fires` 回傳 `true` 的等待立刻結束(期限到、輪詢間隔過了);其他的一直等到 task 被取消
/// (期限還沒到，讓主機的回應先到)。
public actor RecordingSleeper {
    public private(set) var requested: [Duration] = []
    private let fires: @Sendable (Duration) -> Bool

    public init(fires: @escaping @Sendable (Duration) -> Bool = { _ in false }) {
        self.fires = fires
    }

    /// 給被測物注入的 closure。
    public nonisolated var sleep: @Sendable (Duration) async throws -> Void {
        { duration in try await self.wait(duration) }
    }

    private func wait(_ duration: Duration) async throws {
        requested.append(duration)
        if fires(duration) {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(for: .seconds(3600))
    }
}
