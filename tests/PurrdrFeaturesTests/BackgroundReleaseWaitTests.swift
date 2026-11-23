import PurrdrAgentFeatures
import PurrdrCore
import Synchronization
import Testing

/// 進背景放開 Pane 控制最多等 3 秒(#498):送不出去不撐到系統的 background task 到期。
@MainActor
@Suite("進背景放開控制的等待上限")
struct BackgroundReleaseWaitTests {
    private static let forever: Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
    private static let immediately: Sleep = { _ in }

    @Test("放開控制卡住時，到上限就返回")
    func givesUpWhenReleaseHangs() async {
        await BackgroundReleaseWait.wait(for: { try? await Task.sleep(for: .seconds(3600)) }, sleep: Self.immediately)
    }

    @Test("放開控制先完成就立刻返回，不等上限")
    func returnsWhenReleased() async {
        await BackgroundReleaseWait.wait(for: {}, sleep: Self.forever)
    }

    @Test("上限是 3 秒，並傳給注入的等待")
    func limitIsThreeSeconds() async {
        let requested = Mutex<Duration?>(nil)
        await BackgroundReleaseWait.wait(for: { try? await Task.sleep(for: .seconds(3600)) }, sleep: { limit in requested.withLock { $0 = limit } })
        #expect(requested.withLock { $0 } == .seconds(3))
    }
}
