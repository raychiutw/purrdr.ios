import Foundation
import PurrdrFeatures

/// UI 測試(`-uiTesting`)的通知權限替身：不跳系統對話框、不向 APNs 註冊(UI 測試只用 Demo 主機，也不連網路)。
@MainActor
final class UITestingPushPlatform: PushPlatform {
    func authorization() async -> PushAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func deviceToken() async throws -> Data { throw CocoaError(.featureUnsupported) }
    func openSettings() {}
}
