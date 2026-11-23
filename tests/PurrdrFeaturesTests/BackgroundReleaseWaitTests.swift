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

    @Test("放開控制卡住時，到上限就返回", .timeLimit(.minutes(1)))
    func givesUpWhenReleaseHangs() async {
        let started = Mutex(false)
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await BackgroundReleaseWait.wait(for: { started.withLock { $0 = true }; try? await Task.sleep(for: .seconds(3600)) }, sleep: Self.immediately)
        }
        #expect(started.withLock { $0 }, "放開控制沒有開始")
        // 卡住的放開控制要等 3600 秒;上限到了(等待立刻回來)必須在幾秒內返回。
        #expect(elapsed < .seconds(5), "沒有在上限到時返回(等了 \(elapsed))")
    }

    @Test("放開控制先完成就立刻返回，不等上限", .timeLimit(.minutes(1)))
    func returnsWhenReleased() async {
        let released = Mutex(false)
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await BackgroundReleaseWait.wait(for: { released.withLock { $0 = true } }, sleep: Self.forever)
        }
        #expect(released.withLock { $0 }, "放開控制沒有執行")
        #expect(elapsed < .seconds(5), "放開控制先完成卻等了上限(等了 \(elapsed))")
    }

    @Test("上限是 3 秒，並傳給注入的等待")
    func limitIsThreeSeconds() async {
        let requested = Mutex<Duration?>(nil)
        await BackgroundReleaseWait.wait(for: { try? await Task.sleep(for: .seconds(3600)) }, sleep: { limit in requested.withLock { $0 = limit } })
        #expect(requested.withLock { $0 } == .seconds(3))
    }
}
