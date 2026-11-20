import Foundation
import PurrdrCore
import Synchronization

/// UI 測試的 App 鎖替身(#284):不叫出系統 Face ID。
///
/// 第一次解鎖驗證回「取消」(像使用者關掉啟動時的 Face ID),之後一律成功;`-uiTestingNoPasscode` 時沒有裝置密碼。
final class UITestingDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    private let hasPasscode: Bool
    private let unlockAttempts = Mutex(0)

    init(hasPasscode: Bool) {
        self.hasPasscode = hasPasscode
    }

    func availability() -> AppLockAvailability {
        hasPasscode ? .available(.faceID) : .passcodeNotSet
    }

    func authenticate(_ purpose: AppLockAuthenticationPurpose) async -> AppLockAuthenticationResult {
        guard purpose == .unlock else { return .success }
        let attempt = unlockAttempts.withLock { count in
            count += 1
            return count
        }
        return attempt == 1 ? .cancelled : .success
    }
}
