import PurrdrNotificationContent
import UserNotifications

/// Notification Service Extension(#431):推播到達手機後,依 payload 根層的 `pairing` 查 App Group 裡的
/// 「配對雜湊 → 主機名稱」對應表,把主機名稱填進副標題。查不到或來不及就原樣送出(薄殼,規則在 `PushNotificationEnrichment`)。
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        original = request.content
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let enriched = PushNotificationEnrichment.enriched(
            title: mutable.title, subtitle: mutable.subtitle, userInfo: request.content.userInfo,
            hostNames: UserDefaultsPushHostNames().load())
        mutable.title = enriched.title
        mutable.subtitle = enriched.subtitle
        contentHandler(mutable)
    }

    /// 系統給的時間快到了:送出原本的內容(沒有副標題)。
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let original { contentHandler(original) }
    }
}
