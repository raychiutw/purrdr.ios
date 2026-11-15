import PurrdrFeatures
import UIKit
import UserNotifications

/// 推播的 app 層(#29):APNs token 的回呼、前景時不跳系統通知、點通知交給 `PushNotificationRouter`。
@MainActor
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// 由 composition root 在建立時設定(SwiftUI 建 delegate 的時機早於 `App.init` 之後的任何東西)。
    static let platform = SystemPushPlatform()
    static let router = PushNotificationRouter()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        SystemPushPlatform.registerCategories()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.platform.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.platform.didFailToRegister(error)
    }

    /// app 在前景時，新的「需要你」只出現在 Agent 列表，不跳系統通知(HIG 檢核清單)。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    /// 點通知：開該 Agent 的聊天。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let requestID = response.notification.request.identifier
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = PushRoute(userInfo: content.userInfo) else { return }
        await MainActor.run { Self.router.receive(route, requestID: requestID) }
    }
}
