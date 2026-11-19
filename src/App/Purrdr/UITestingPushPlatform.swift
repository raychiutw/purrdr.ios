import Foundation
import PurrdrFeatures

/// UI 測試(`-uiTesting`)的通知權限替身：不跳系統對話框、不向 APNs 註冊。
/// 以假會員啟動時(#246)當作已允許通知，給固定的裝置權杖;否則一律拒絕。
@MainActor
final class UITestingPushPlatform: PushPlatform {
    private let isAuthorized: Bool

    init(isAuthorized: Bool) {
        self.isAuthorized = isAuthorized
    }

    func authorization() async -> PushAuthorization { isAuthorized ? .authorized : .denied }
    func requestAuthorization() async -> Bool { isAuthorized }
    func deviceToken() async throws -> Data {
        guard isAuthorized else { throw CocoaError(.featureUnsupported) }
        return Data(repeating: 0xAB, count: 32)
    }
    func openSettings() {}
}
