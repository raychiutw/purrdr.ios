import Foundation
import Testing

@testable import PurrdrCore

@MainActor
private final class FakeScheduler: BackgroundTaskScheduling {
    var remaining: TimeInterval = 30
    var grants = true
    private(set) var begun = 0
    private(set) var ended: [Int] = []
    private(set) var scheduledSeconds: [TimeInterval] = []
    private(set) var cancelled = 0
    var expiration: (@MainActor () -> Void)?
    var fire: (@MainActor () -> Void)?

    func begin(expiration: @escaping @MainActor () -> Void) -> Int? {
        guard grants else { return nil }
        begun += 1
        self.expiration = expiration
        return begun
    }
    func end(_ task: Int) { ended.append(task) }
    func remainingTime() -> TimeInterval { remaining }
    func schedule(after seconds: TimeInterval, fire: @escaping @MainActor () -> Void) -> () -> Void {
        scheduledSeconds.append(seconds)
        self.fire = fire
        return { [self] in cancelled += 1 }
    }
}

@MainActor
@Suite("進背景保留連線(#551)")
struct BackgroundRetentionControllerTests {
    @Test("保留時間:剩餘的 9 成、上限 25 秒")
    func retentionSeconds() {
        #expect(BackgroundRetentionController.retentionSeconds(remaining: 30) == 25)
        #expect(BackgroundRetentionController.retentionSeconds(remaining: 20) == 18)
        #expect(BackgroundRetentionController.retentionSeconds(remaining: 0) == 0)
        #expect(BackgroundRetentionController.retentionSeconds(remaining: -5) == 0)
        #expect(BackgroundRetentionController.retentionSeconds(remaining: .infinity) == 25)
    }

    @Test("進背景且沒鎖定:申請 task,排程在保留時間結束")
    func beginsWhenUnlocked() {
        let scheduler = FakeScheduler()
        let controller = BackgroundRetentionController(scheduler: scheduler)
        controller.didEnterBackground(isDeviceLocked: false)
        #expect(controller.isRetaining)
        #expect(scheduler.scheduledSeconds == [25])
    }

    @Test("剩餘時間短:保留時間取 9 成")
    func shortRemaining() {
        let scheduler = FakeScheduler()
        scheduler.remaining = 10
        let controller = BackgroundRetentionController(scheduler: scheduler)
        controller.didEnterBackground(isDeviceLocked: false)
        #expect(scheduler.scheduledSeconds == [9])
    }

    @Test("裝置鎖定:不申請")
    func locked() {
        let scheduler = FakeScheduler()
        let controller = BackgroundRetentionController(scheduler: scheduler)
        controller.didEnterBackground(isDeviceLocked: true)
        #expect(scheduler.begun == 0)
        #expect(!controller.isRetaining)
    }

    @Test("回前景:結束 task 並取消計時")
    func becomeActive() {
        let scheduler = FakeScheduler()
        let controller = BackgroundRetentionController(scheduler: scheduler)
        controller.didEnterBackground(isDeviceLocked: false)
        controller.didBecomeActive()
        #expect(scheduler.ended == [1])
        #expect(scheduler.cancelled == 1)
        #expect(!controller.isRetaining)
    }

    @Test("時間到:結束 task,只結束一次")
    func timeout() {
        let scheduler = FakeScheduler()
        let controller = BackgroundRetentionController(scheduler: scheduler)
        controller.didEnterBackground(isDeviceLocked: false)
        scheduler.fire?()
        controller.didBecomeActive()
        #expect(scheduler.ended == [1])
    }

    @Test("expiry handler:立刻結束 task")
    func expiry() {
        let scheduler = FakeScheduler()
        let controller = BackgroundRetentionController(scheduler: scheduler)
        controller.didEnterBackground(isDeviceLocked: false)
        scheduler.expiration?()
        #expect(scheduler.ended == [1])
        #expect(scheduler.cancelled == 1)
        #expect(!controller.isRetaining)
    }

    @Test("申請不到或沒有剩餘時間:不保留;重複進背景不重複申請")
    func edges() {
        let denied = FakeScheduler()
        denied.grants = false
        let a = BackgroundRetentionController(scheduler: denied)
        a.didEnterBackground(isDeviceLocked: false)
        #expect(!a.isRetaining)

        let none = FakeScheduler()
        none.remaining = 0
        let b = BackgroundRetentionController(scheduler: none)
        b.didEnterBackground(isDeviceLocked: false)
        #expect(none.ended == [1])
        #expect(!b.isRetaining)

        let twice = FakeScheduler()
        let c = BackgroundRetentionController(scheduler: twice)
        c.didEnterBackground(isDeviceLocked: false)
        c.didEnterBackground(isDeviceLocked: false)
        #expect(twice.begun == 1)
    }

    @Test("保留期內回前景沿用連線(與 #550 的策略一致)")
    func retentionMatchesReconnectPolicy() {
        #expect(ForegroundReconnectPolicy.decision(backgroundSeconds: BackgroundRetention.duration) == .reuse)
    }
}
