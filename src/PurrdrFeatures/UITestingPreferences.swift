import Foundation

/// UI 測試(`-uiTesting`)啟動時的偏好重置(#370)。
///
/// 選取主機、目前主機、列表檢視、離線佇列、歡迎頁已看過、流量統計、聊天快取等本機狀態在 `-uiTesting` 下都是記憶體實作;
/// 剩下只能走 `UserDefaults.standard` 的是設定頁偏好(`@AppStorage` 與設定頁寫入同一個 key,`-appearance` 之類的
/// 啟動參數也靠 argument domain 覆寫它)。啟動時清掉 app 自己的持久區,讓上一個測試留下的值不影響這一個,
/// 測試之間就沒有執行順序依賴。argument domain(啟動參數)不是持久區,不受影響。
public enum UITestingPreferences {
    /// 清掉 `domain`(通常是 bundle id)在 `defaults` 的持久區。
    public static func resetPersistedState(in defaults: UserDefaults, domain: String) {
        defaults.removePersistentDomain(forName: domain)
    }
}
