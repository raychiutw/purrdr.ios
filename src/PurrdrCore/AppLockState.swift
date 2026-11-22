import Foundation

/// 這支裝置的生物辨識種類(設定頁的開關文字用)。`passcodeOnly` 只有裝置密碼。
public enum AppLockBiometry: Sendable, Equatable {
    case faceID, touchID, opticID, passcodeOnly
}

/// App 鎖能不能用。沒有裝置密碼時不能用(系統無法驗證裝置擁有者)。
public enum AppLockAvailability: Sendable, Equatable {
    case available(AppLockBiometry)
    case passcodeNotSet
    case unavailable

    public var canAuthenticate: Bool {
        if case .available = self { true } else { false }
    }
}

/// 驗證裝置擁有者的結果。生物辨識失敗後在系統畫面改用裝置密碼通過，也是 `success`。
public enum AppLockAuthenticationResult: Sendable, Equatable {
    case success, cancelled, failed
}

/// 為什麼要驗證(系統畫面的說明文字由平台實作決定)。
public enum AppLockAuthenticationPurpose: Sendable, Equatable {
    case unlock, turnOn
    /// 轉移訂閱等會改動帳號的操作(#409):確認是裝置擁有者本人。
    case confirmAccountChange
}

/// 驗證裝置擁有者(iOS 是 `LocalAuthentication` 的 `deviceOwnerAuthentication`,允許改用裝置密碼)。
public protocol DeviceOwnerAuthenticating: Sendable {
    func availability() -> AppLockAvailability
    func authenticate(_ purpose: AppLockAuthenticationPurpose) async -> AppLockAuthenticationResult
}

/// App 的生命週期(場景整體)。
public enum AppLockPhase: Sendable, Equatable {
    case active, inactive, background
}

/// App 鎖的鎖定狀態(#284):冷啟動，或離開超過 `gracePeriod` 再回來時鎖定。
///
/// 進背景時就先鎖上，回來時在期限內才自動解除，所以回到前景前到達的推播導航也會延後。
public struct AppLockState: Sendable, Equatable {
    public static let gracePeriod: TimeInterval = 60

    public private(set) var isEnabled: Bool
    public private(set) var availability: AppLockAvailability
    public private(set) var isLocked: Bool
    private var wantsAutomaticUnlock: Bool
    private var phase: AppLockPhase?
    /// 離開前是解鎖的：進背景的時間。
    private var unlockedUntilBackgroundAt: Date?

    /// 冷啟動。
    public init(isEnabled: Bool, availability: AppLockAvailability) {
        self.isEnabled = isEnabled
        self.availability = availability
        isLocked = isEnabled && availability.canAuthenticate
        wantsAutomaticUnlock = isLocked
    }

    /// 開啟且這支裝置驗證得了。
    public var isActive: Bool { isEnabled && availability.canAuthenticate }

    public mutating func sceneChanged(to newPhase: AppLockPhase, at now: Date) {
        let oldPhase = phase
        phase = newPhase
        guard isActive, oldPhase != newPhase else { return }
        if newPhase == .background {
            unlockedUntilBackgroundAt = isLocked ? nil : now
            isLocked = true
        } else if oldPhase == .background {
            if let leftAt = unlockedUntilBackgroundAt, now.timeIntervalSince(leftAt) <= Self.gracePeriod {
                isLocked = false
            } else {
                wantsAutomaticUnlock = true
            }
            unlockedUntilBackgroundAt = nil
        }
    }

    /// 回到前景時要不要自動叫出驗證;每次鎖定只回 `true` 一次(取消後由使用者按「解鎖」)。
    public mutating func takeAutomaticUnlock() -> Bool {
        guard isLocked, wantsAutomaticUnlock, phase == .active else { return false }
        wantsAutomaticUnlock = false
        return true
    }

    public mutating func authenticated(_ result: AppLockAuthenticationResult) {
        guard result == .success, phase != .background else { return }
        isLocked = false
    }

    /// 裝置密碼被移除等：驗證不了就不鎖，避免永遠進不去。
    public mutating func availabilityChanged(_ newAvailability: AppLockAvailability) {
        availability = newAvailability
        if !isActive { unlock() }
    }

    /// 開啟前由呼叫端先驗證一次;在前景開啟不會馬上鎖住。
    public mutating func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { unlock() }
    }

    /// 視窗要不要蓋上遮蔽：鎖定中，或視窗不在前景(多工切換畫面的截圖)。
    public func covers(windowIsActive: Bool) -> Bool {
        isActive && (isLocked || !windowIsActive)
    }

    private mutating func unlock() {
        isLocked = false
        wantsAutomaticUnlock = false
        unlockedUntilBackgroundAt = nil
    }
}
