#if os(iOS)
import UIKit
import UserNotifications

/// iOS 的通知權限與 APNs token(`PushPlatform` 的正式實作)。
///
/// APNs token 經 app delegate 的 `didRegisterForRemoteNotificationsWithDeviceToken` 送回來，
/// app 要把它轉給 `didRegister(deviceToken:)`／`didFailToRegister(_:)`。
@MainActor
public final class SystemPushPlatform: PushPlatform {
    /// 推播的通知類別：設定隱藏預覽時的通用文字(HIG)。後台的 payload 帶同一個 `category`。
    public static let blockedCategory = "AGENT_BLOCKED"

    private var waiting: [CheckedContinuation<Data, any Error>] = []

    public init() {}

    public func authorization() async -> PushAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func deviceToken() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    public func didRegister(deviceToken: Data) {
        let waiting = waiting
        self.waiting = []
        for continuation in waiting { continuation.resume(returning: deviceToken) }
    }

    public func didFailToRegister(_ error: any Error) {
        let waiting = waiting
        self.waiting = []
        for continuation in waiting { continuation.resume(throwing: error) }
    }

    public func openSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// 註冊通知類別(啟動時呼叫一次，不會請求權限)。
    public static func registerCategories() {
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: blockedCategory, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "An agent needs you"), options: [])
        ])
    }
}
#endif
