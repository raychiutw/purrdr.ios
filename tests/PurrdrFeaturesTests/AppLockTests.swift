import Foundation
import LocalAuthentication
import PurrdrCore
import PurrdrFeatures
import Testing

/// App 鎖(#284):驗證、本機設定、推播導航延到解鎖後。鎖定時機在 `AppLockStateTests`。
@MainActor
@Suite("App 鎖")
struct AppLockTests {
    /// 依序回答驗證結果的假生物辨識介面;沒有預備結果時回 `cancelled`。
    final class ScriptedAuthenticator: DeviceOwnerAuthenticating, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [AppLockAuthenticationResult]
        private var recorded: [AppLockAuthenticationPurpose] = []
        let currentAvailability: AppLockAvailability

        init(_ results: [AppLockAuthenticationResult] = [], availability: AppLockAvailability = .available(.faceID)) {
            self.results = results
            currentAvailability = availability
        }

        var purposes: [AppLockAuthenticationPurpose] { lock.withLock { recorded } }

        func availability() -> AppLockAvailability { currentAvailability }

        func authenticate(_ purpose: AppLockAuthenticationPurpose) async -> AppLockAuthenticationResult {
            lock.withLock {
                recorded.append(purpose)
                return results.isEmpty ? .cancelled : results.removeFirst()
            }
        }
    }

    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func defaults(enabled: Bool? = nil) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "app-lock-\(UUID().uuidString)")!
        if let enabled { defaults.set(enabled, forKey: AppLock.enabledKey) }
        return defaults
    }

    @Test("預設關閉：沒設定過不鎖定")
    func defaultsToOff() {
        let lock = AppLock(authenticator: ScriptedAuthenticator(), defaults: Self.defaults())

        #expect(!lock.isEnabled)
        #expect(!lock.isLocked)
    }

    @Test("冷啟動回到前景自動驗證一次;取消後留在鎖定畫面，按「解鎖」成功才解鎖")
    func coldStartPromptsOnceThenManualUnlock() async {
        let authenticator = ScriptedAuthenticator([.cancelled, .success])
        let lock = AppLock(authenticator: authenticator, defaults: Self.defaults(enabled: true))

        lock.scenePhaseChanged(to: .active, at: Self.now)
        await lock.automaticUnlock?.value
        #expect(lock.isLocked)

        // 系統驗證畫面消失後 app 又回到 active:不再自動跳出。
        lock.scenePhaseChanged(to: .inactive, at: Self.now)
        lock.scenePhaseChanged(to: .active, at: Self.now)
        await lock.automaticUnlock?.value
        #expect(authenticator.purposes == [.unlock])

        await lock.unlock()
        #expect(!lock.isLocked)
    }

    @Test("推播開啟的導航延到解鎖後才執行")
    func notificationNavigationWaitsForUnlock() async {
        let lock = AppLock(authenticator: ScriptedAuthenticator([.success]), defaults: Self.defaults(enabled: true))
        var opened: [String] = []

        lock.whenUnlocked { opened.append("w1:p1") }
        #expect(opened.isEmpty, "鎖定中不該導航")

        await lock.unlock()
        #expect(opened == ["w1:p1"])
    }

    @Test("鎖定中點了好幾則通知，解鎖後只開最後一則")
    func onlyLatestDeferredNavigationRuns() async {
        let lock = AppLock(authenticator: ScriptedAuthenticator([.success]), defaults: Self.defaults(enabled: true))
        var opened: [String] = []

        lock.whenUnlocked { opened.append("w1:p1") }
        lock.whenUnlocked { opened.append("w2:p1") }
        await lock.unlock()

        #expect(opened == ["w2:p1"])
    }

    @Test("驗證失敗時導航繼續等")
    func failedAuthenticationKeepsNavigationWaiting() async {
        let lock = AppLock(authenticator: ScriptedAuthenticator([.failed]), defaults: Self.defaults(enabled: true))
        var opened: [String] = []

        lock.whenUnlocked { opened.append("w1:p1") }
        await lock.unlock()

        #expect(lock.isLocked)
        #expect(opened.isEmpty)
    }

    @Test("沒鎖定時導航立即執行")
    func navigationRunsImmediatelyWhenUnlocked() {
        let lock = AppLock(authenticator: ScriptedAuthenticator(), defaults: Self.defaults())
        var opened: [String] = []

        lock.whenUnlocked { opened.append("w1:p1") }

        #expect(opened == ["w1:p1"])
    }

    @Test("離開超過 1 分鐘回來時到達的推播，等解鎖後才導航")
    func navigationArrivingWhileBackgroundedWaits() async {
        let lock = AppLock(authenticator: ScriptedAuthenticator([.success, .cancelled]), defaults: Self.defaults(enabled: true))
        lock.scenePhaseChanged(to: .active, at: Self.now)
        await lock.automaticUnlock?.value
        var opened: [String] = []

        lock.scenePhaseChanged(to: .background, at: Self.now)
        lock.whenUnlocked { opened.append("w1:p1") }
        lock.scenePhaseChanged(to: .inactive, at: Self.now.addingTimeInterval(61))
        lock.scenePhaseChanged(to: .active, at: Self.now.addingTimeInterval(61))
        await lock.automaticUnlock?.value

        #expect(lock.isLocked)
        #expect(opened.isEmpty)
    }

    @Test("1 分鐘內回來時到達的推播，回到前景就導航")
    func navigationArrivingWithinGracePeriodRunsOnReturn() async {
        let lock = AppLock(authenticator: ScriptedAuthenticator([.success]), defaults: Self.defaults(enabled: true))
        lock.scenePhaseChanged(to: .active, at: Self.now)
        await lock.automaticUnlock?.value
        var opened: [String] = []

        lock.scenePhaseChanged(to: .background, at: Self.now)
        lock.whenUnlocked { opened.append("w1:p1") }
        lock.scenePhaseChanged(to: .inactive, at: Self.now.addingTimeInterval(30))

        #expect(opened == ["w1:p1"])
    }

    @Test("開啟 App 鎖要先驗證;取消就維持關閉")
    func turningOnRequiresAuthentication() async {
        let defaults = Self.defaults()
        let authenticator = ScriptedAuthenticator([.cancelled, .success])
        let lock = AppLock(authenticator: authenticator, defaults: defaults)

        await lock.setEnabled(true)
        #expect(!lock.isEnabled)

        await lock.setEnabled(true)
        #expect(lock.isEnabled)
        #expect(!lock.isLocked, "在前景開啟不會馬上鎖住")
        #expect(authenticator.purposes == [.turnOn, .turnOn])
        #expect(defaults.bool(forKey: AppLock.enabledKey), "設定存在本機偏好")
    }

    @Test("關閉 App 鎖不用驗證，並執行等待中的導航")
    func turningOffRunsWaitingNavigation() async {
        let defaults = Self.defaults(enabled: true)
        let lock = AppLock(authenticator: ScriptedAuthenticator(), defaults: defaults)
        var opened: [String] = []
        lock.whenUnlocked { opened.append("w1:p1") }

        await lock.setEnabled(false)

        #expect(!lock.isEnabled)
        #expect(opened == ["w1:p1"])
        #expect(!defaults.bool(forKey: AppLock.enabledKey))
    }

    @Test("沒有裝置密碼時不能開啟，也不鎖定")
    func noPasscodeCannotTurnOn() async {
        let authenticator = ScriptedAuthenticator([.success], availability: .passcodeNotSet)
        let lock = AppLock(authenticator: authenticator, defaults: Self.defaults(enabled: true))

        #expect(!lock.isLocked)
        #expect(lock.availability == .passcodeNotSet)
        await lock.setEnabled(true)
        #expect(authenticator.purposes.isEmpty)
    }

    @Test("系統驗證允許生物辨識失敗後改用裝置密碼")
    func systemAuthenticatorAllowsPasscodeFallback() {
        #expect(SystemDeviceOwnerAuthenticator.policy == .deviceOwnerAuthentication)
    }
}
