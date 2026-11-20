import Foundation
import LocalAuthentication
import Observation
import PurrdrCore

/// App 鎖(#284)。所有視窗共用一份;鎖定時機在核心的 `AppLockState`。
@MainActor
@Observable
public final class AppLock {
    /// 本機偏好(不同步),預設關閉。
    public static let enabledKey = "appLockEnabled"

    public private(set) var state: AppLockState
    public private(set) var isAuthenticating = false
    /// 回到前景時自動叫出的驗證(測試等它結束)。
    @ObservationIgnored package private(set) var automaticUnlock: Task<Void, Never>?
    @ObservationIgnored private var waitingNavigation: (@MainActor () -> Void)?
    @ObservationIgnored private let authenticator: any DeviceOwnerAuthenticating
    @ObservationIgnored private let defaults: UserDefaults

    public init(authenticator: any DeviceOwnerAuthenticating, defaults: UserDefaults) {
        self.authenticator = authenticator
        self.defaults = defaults
        state = AppLockState(isEnabled: defaults.bool(forKey: Self.enabledKey), availability: authenticator.availability())
    }

    public var isEnabled: Bool { state.isEnabled }
    public var isLocked: Bool { state.isLocked }
    public var availability: AppLockAvailability { state.availability }

    /// 視窗要不要蓋上鎖定畫面(鎖定中，或視窗不在前景時遮蔽多工切換畫面)。
    public func covers(windowIsActive: Bool) -> Bool {
        state.covers(windowIsActive: windowIsActive)
    }

    /// 場景整體的生命週期。冷啟動或離開超過 1 分鐘回來時，回到前景自動叫出一次驗證。
    public func scenePhaseChanged(to phase: AppLockPhase, at now: Date) {
        if phase == .active { state.availabilityChanged(authenticator.availability()) }
        state.sceneChanged(to: phase, at: now)
        runWaitingNavigationIfUnlocked()
        if state.takeAutomaticUnlock() {
            automaticUnlock = Task { await unlock() }
        }
    }

    /// 解鎖後才執行的導航(推播點擊)。沒鎖定就立即執行;鎖定中只留最後一個。
    public func whenUnlocked(_ navigation: @escaping @MainActor () -> Void) {
        guard state.isLocked else {
            navigation()
            return
        }
        waitingNavigation = navigation
    }

    public func unlock() async {
        guard state.isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        let result = await authenticator.authenticate(.unlock)
        isAuthenticating = false
        state.authenticated(result)
        runWaitingNavigationIfUnlocked()
    }

    /// 開啟前先驗證一次(確認解得開);關閉不用驗證。
    public func setEnabled(_ enabled: Bool) async {
        if enabled {
            refreshAvailability()
            guard !state.isEnabled, state.availability.canAuthenticate, !isAuthenticating else { return }
            isAuthenticating = true
            let result = await authenticator.authenticate(.turnOn)
            isAuthenticating = false
            guard result == .success else { return }
        }
        state.setEnabled(enabled)
        defaults.set(enabled, forKey: Self.enabledKey)
        runWaitingNavigationIfUnlocked()
    }

    /// 設定頁打開時重讀(使用者可能剛設定或移除裝置密碼)。
    public func refreshAvailability() {
        state.availabilityChanged(authenticator.availability())
        runWaitingNavigationIfUnlocked()
    }

    private func runWaitingNavigationIfUnlocked() {
        guard !state.isLocked, let navigation = waitingNavigation else { return }
        waitingNavigation = nil
        navigation()
    }
}

/// 系統的裝置擁有者驗證：Face ID／Touch ID／Optic ID,失敗可改用裝置密碼。
public struct SystemDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    /// 允許改用裝置密碼的 policy(只有生物辨識的 policy 不會提供密碼)。
    public static let policy = LAPolicy.deviceOwnerAuthentication

    public init() {}

    public func availability() -> AppLockAvailability {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(Self.policy, error: &error) else {
            let isPasscodeNotSet = error?.domain == LAErrorDomain && error?.code == LAError.Code.passcodeNotSet.rawValue
            return isPasscodeNotSet ? .passcodeNotSet : .unavailable
        }
        switch context.biometryType {
        case .faceID: return .available(.faceID)
        case .touchID: return .available(.touchID)
        case .opticID: return .available(.opticID)
        default: return .available(.passcodeOnly)
        }
    }

    public func authenticate(_ purpose: AppLockAuthenticationPurpose) async -> AppLockAuthenticationResult {
        let reason = switch purpose {
        case .unlock: String(localized: "Unlock Purrdr to see your chats.")
        case .turnOn: String(localized: "Confirm it’s you to turn on App Lock.")
        }
        do {
            return try await LAContext().evaluatePolicy(Self.policy, localizedReason: reason) ? .success : .failed
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel: return .cancelled
            default: return .failed
            }
        } catch {
            return .failed
        }
    }
}
