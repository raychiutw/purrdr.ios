import Foundation
import PurrdrCore
import Testing

/// App 鎖(#284):冷啟動、離開 59／61 秒、驗證失敗、改用裝置密碼、沒有裝置密碼。
@Suite("App 鎖的鎖定狀態")
struct AppLockStateTests {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let available = AppLockAvailability.available(.faceID)

    static func unlockedInForeground(at now: Date = start) -> AppLockState {
        var state = AppLockState(isEnabled: true, availability: available)
        state.sceneChanged(to: .active, at: now)
        _ = state.takeAutomaticUnlock()
        state.authenticated(.success)
        return state
    }

    @Test("開啟 App 鎖時冷啟動是鎖定，回到前景自動叫出一次驗證")
    func coldStartIsLocked() {
        var state = AppLockState(isEnabled: true, availability: Self.available)

        #expect(state.isLocked)
        state.sceneChanged(to: .active, at: Self.start)
        let firstPrompt = state.takeAutomaticUnlock()
        let secondPrompt = state.takeAutomaticUnlock()
        #expect(firstPrompt)
        #expect(!secondPrompt, "自動驗證只叫一次，取消後不會一直跳出來")
    }

    @Test("預設關閉：冷啟動不鎖定")
    func disabledNeverLocks() {
        var state = AppLockState(isEnabled: false, availability: Self.available)
        state.sceneChanged(to: .active, at: Self.start)

        #expect(!state.isLocked)
        let prompts = state.takeAutomaticUnlock()
        #expect(!prompts)
    }

    @Test("驗證成功才解鎖;失敗或取消仍鎖定")
    func authenticationResultDecidesUnlock() {
        var state = AppLockState(isEnabled: true, availability: Self.available)
        state.sceneChanged(to: .active, at: Self.start)

        state.authenticated(.failed)
        #expect(state.isLocked)
        state.authenticated(.cancelled)
        #expect(state.isLocked)
        // 生物辨識失敗後在系統畫面改用裝置密碼，結果一樣是成功。
        state.authenticated(.success)
        #expect(!state.isLocked)
    }

    @Test("離開 59 秒回來不用解鎖")
    func returningWithinGracePeriodStaysUnlocked() {
        var state = Self.unlockedInForeground()

        state.sceneChanged(to: .background, at: Self.start)
        #expect(state.isLocked, "在背景時先鎖上，回來前的推播導航會延後")
        state.sceneChanged(to: .inactive, at: Self.start.addingTimeInterval(59))
        state.sceneChanged(to: .active, at: Self.start.addingTimeInterval(59))

        #expect(!state.isLocked)
        let prompts = state.takeAutomaticUnlock()
        #expect(!prompts)
    }

    @Test("離開 61 秒回來要解鎖，並自動叫出驗證")
    func returningAfterGracePeriodLocks() {
        var state = Self.unlockedInForeground()

        state.sceneChanged(to: .background, at: Self.start)
        state.sceneChanged(to: .inactive, at: Self.start.addingTimeInterval(61))
        state.sceneChanged(to: .active, at: Self.start.addingTimeInterval(61))

        #expect(state.isLocked)
        let prompts = state.takeAutomaticUnlock()
        #expect(prompts)
    }

    @Test("還沒解鎖就離開，59 秒內回來仍是鎖定")
    func lockedBeforeLeavingStaysLocked() {
        var state = AppLockState(isEnabled: true, availability: Self.available)
        state.sceneChanged(to: .active, at: Self.start)
        _ = state.takeAutomaticUnlock()

        state.sceneChanged(to: .background, at: Self.start)
        state.sceneChanged(to: .active, at: Self.start.addingTimeInterval(5))

        #expect(state.isLocked)
    }

    @Test("下拉控制中心(只到 inactive)回來不鎖定")
    func inactiveWithoutBackgroundDoesNotLock() {
        var state = Self.unlockedInForeground()

        state.sceneChanged(to: .inactive, at: Self.start)
        state.sceneChanged(to: .active, at: Self.start.addingTimeInterval(120))

        #expect(!state.isLocked)
    }

    @Test("沒有裝置密碼時 App 鎖不可用、不鎖定")
    func noPasscodeNeverLocks() {
        var state = AppLockState(isEnabled: true, availability: .passcodeNotSet)
        state.sceneChanged(to: .active, at: Self.start)

        #expect(!state.isLocked)
        #expect(!state.isActive)
        let prompts = state.takeAutomaticUnlock()
        #expect(!prompts)
    }

    @Test("裝置密碼被移除時解除鎖定，避免永遠進不去")
    func losingPasscodeUnlocks() {
        var state = AppLockState(isEnabled: true, availability: Self.available)

        state.availabilityChanged(.passcodeNotSet)

        #expect(!state.isLocked)
    }

    @Test("關閉 App 鎖立即解除")
    func turningOffUnlocks() {
        var state = AppLockState(isEnabled: true, availability: Self.available)

        state.setEnabled(false)

        #expect(!state.isLocked)
        #expect(!state.isEnabled)
    }

    @Test("在前景開啟 App 鎖不會馬上鎖住")
    func turningOnWhileInForegroundKeepsUnlocked() {
        var state = AppLockState(isEnabled: false, availability: Self.available)
        state.sceneChanged(to: .active, at: Self.start)

        state.setEnabled(true)

        #expect(state.isEnabled)
        #expect(!state.isLocked)
    }

    @Test("鎖定中或視窗不在前景時遮蔽內容(多工切換畫面)")
    func coverRule() {
        var state = Self.unlockedInForeground()
        #expect(!state.covers(windowIsActive: true))
        #expect(state.covers(windowIsActive: false))

        state.setEnabled(false)
        #expect(!state.covers(windowIsActive: false), "關閉時多工切換畫面照常顯示")

        let locked = AppLockState(isEnabled: true, availability: Self.available)
        #expect(locked.covers(windowIsActive: true))
    }
}
