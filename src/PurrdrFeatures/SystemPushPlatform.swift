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
    /// 「完成」的通知類別(raychiutw/purrdr.server#10)。
    public static let doneCategory = "AGENT_DONE"
    /// 主機服務事件的通知類別(raychiutw/purrdr.server#11)。
    public static let hostServiceCategory = "HOST_SERVICE_EVENT"
    /// 「可能卡住」的通知類別(raychiutw/purrdr.server#15,一般等級)。
    public static let stuckCategory = "AGENT_STUCK"
    /// 「仍在等你」的通知類別(raychiutw/purrdr.server#15,time-sensitive)。
    public static let reminderCategory = "AGENT_REMINDER"

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

    /// 推播內文：後台的 APNs payload 只送 `loc-key`,由系統以 app 的字串表翻譯。
    /// 寫在程式碼裡，`scripts/strings.sh` 才抽得到這個 key(否則會當成已不用而移除)。
    static let blockedBody = String(localized: "An agent needs you.", comment: "推播內文(後台 APNs payload 的 loc-key)")
    static let doneBody = String(localized: "An agent finished.", comment: "「完成」推播內文(後台 APNs payload 的 loc-key)")
    static let stuckBody = String(localized: "An agent may be stuck.", comment: "「可能卡住」推播內文(後台 APNs payload 的 loc-key)")
    static let reminderBody = String(
        localized: "An agent is still waiting for you.", comment: "「仍在等你」推播內文(後台 APNs payload 的 loc-key)")
    /// 主機服務事件：標題是 `title-loc-key`,「已更新」以 `loc-args` 帶入版本。
    static let hostServiceTitle = String(localized: "Host service", comment: "主機服務推播標題(後台 APNs payload 的 title-loc-key)")
    static let hostServiceUpdateAvailableBody = String(
        localized: "A host service update is available.", comment: "主機服務推播內文：有新版(後台 APNs payload 的 loc-key)")
    static let hostServiceUpdatedBody = String(
        localized: "Host service updated to %@.", comment: "主機服務推播內文：已更新到某版(後台 APNs payload 的 loc-key,%@ 是版本)")
    static let hostServiceRolledBackBody = String(
        localized: "Host service update failed and was rolled back.", comment: "主機服務推播內文：更新失敗已退回(後台 APNs payload 的 loc-key)")

    /// 每日上限通知(#675,`event: "daily_limit_reached"`):標題 `title-loc-key`、內文 `loc-key` 以 `loc-args` 帶入上限數字。
    static let dailyLimitTitle = String(
        localized: "Daily notification limit reached", comment: "每日通知上限通知標題(後台 APNs payload 的 title-loc-key)")
    static func dailyLimitBody(limit: String) -> String {
        String(
            localized: "You've reached today's limit of \(limit) notifications. They'll resume at 00:00 UTC.",
            comment: "每日通知上限通知內文(後台 APNs payload 的 loc-key,%@ 是上限數字;後台以 UTC 0:00 歸零)")
    }

    /// 新通知種類(#707,後台 purrdr.server#39～#43):文字全是後台送的英文 `loc-key`,由系統查字串表翻譯。
    /// 長時間工作完成(`long_work_done`)。
    static let longWorkDoneBody = String(
        localized: "An agent finished a long task.", comment: "「長時間工作完成」推播內文(後台 APNs payload 的 loc-key)")
    /// 預約送出被暫停(`queue_paused`):`loc-args` 是 Tab 名稱,沒有 Tab 時用不帶參數的版本。
    static func queuePausedBody(tab: String) -> String {
        String(
            localized: "Queue paused in \(tab).",
            comment: "「預約送出被暫停」推播內文(後台 APNs payload 的 loc-key,%@ 是 Tab 名稱)")
    }
    static let queuePausedBodyWithoutTab = String(
        localized: "Queue paused.", comment: "「預約送出被暫停」推播內文(沒有 Tab 名稱時;後台 APNs payload 的 loc-key)")
    /// 方案用量快用完(`usage_alert`):標題 `title-loc-key`,內文 `loc-args` 是 Agent 名稱(Claude 或 Codex)與門檻(80 或 95)。
    static let usageAlertTitle = String(localized: "Plan usage", comment: "「方案用量快用完」推播標題(後台 APNs payload 的 title-loc-key)")
    static func usageAlertBody(agent: String, percent: String) -> String {
        String(
            localized: "Your \(agent) plan usage reached \(percent)%.",
            comment: "「方案用量快用完」推播內文(後台 APNs payload 的 loc-key,第一個 %@ 是 Agent 名稱、第二個是門檻百分比)")
    }
    /// 主機離線與已恢復(`host_offline`／`host_recovered`):只有標題。
    static let hostOfflineTitle = String(localized: "Host offline", comment: "「主機離線」推播標題(後台 APNs payload 的 title)")
    static let hostRecoveredTitle = String(localized: "Host back online", comment: "「主機已恢復」推播標題(後台 APNs payload 的 title)")
    /// 內文(purrdr.server `src/presence.ts`;沒有 `loc-args`)。
    static let hostOfflineBody = String(
        localized: "Your computer appears to be offline.", comment: "「主機離線」推播內文(後台 APNs payload 的 loc-key)")
    static let hostRecoveredBody = String(
        localized: "Your computer is back online.", comment: "「主機已恢復」推播內文(後台 APNs payload 的 loc-key)")

    /// 測試通知(#328,`event: "test"`):標題 `title-loc-key` 帶主機名稱(`loc-args`),沒有名稱時用不帶參數的版本。
    static func testTitle(hostName: String) -> String {
        String(localized: "Test: \(hostName) needs you", comment: "測試通知標題(後台 APNs payload 的 title-loc-key,%@ 是主機清單上的主機名稱)")
    }
    static let testTitleWithoutHost = String(
        localized: "Test: Purrdr needs you", comment: "測試通知標題(沒帶主機名稱時;後台 APNs payload 的 title-loc-key)")
    static let testBody = String(
        localized: "This is a test. When an agent needs your reply or finishes, you'll get a notice like this.",
        comment: "測試通知內文(後台 APNs payload 的 loc-key)")

    /// 註冊通知類別(啟動時呼叫一次，不會請求權限)。
    public static func registerCategories() {
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: blockedCategory, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "An agent needs you"), options: []),
            UNNotificationCategory(
                identifier: doneCategory, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "An agent finished"), options: []),
            UNNotificationCategory(
                identifier: hostServiceCategory, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "Host service update"), options: []),
            UNNotificationCategory(
                identifier: stuckCategory, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "An agent may be stuck"), options: []),
            UNNotificationCategory(
                identifier: reminderCategory, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "An agent is still waiting for you"), options: []),
        ])
    }
}
#endif
