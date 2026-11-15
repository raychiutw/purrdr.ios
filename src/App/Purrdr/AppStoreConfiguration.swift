import Foundation
import PurrdrFeatures

/// App Store 與支援頁的設定。
///
/// 標成 REPLACE_ME 的值上線前要換成真值:App Store id 在 App Store Connect 建立 app 後取得(數字)。
/// 還是佔位符時，「為 Purrdr 評分」會打開一個找不到的 App Store 頁面，其他功能不受影響。
enum AppStoreConfiguration {
    static let appStoreID = "REPLACE_ME"

    /// 隱私權政策與支援頁放在 `raychiutw.github.io/purrdr/`(#2「資料與隱私」)。實際路徑以網站上線時為準。
    static let settingsLinks = SettingsLinks(
        appStoreID: appStoreID,
        support: URL(string: "https://raychiutw.github.io/purrdr/support/")!,
        privacyPolicy: URL(string: "https://raychiutw.github.io/purrdr/privacy/")!
    )
}
