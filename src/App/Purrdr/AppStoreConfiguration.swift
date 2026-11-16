import Foundation
import PurrdrFeatures

/// 設定頁的外部連結。App Store id、隱私權政策、支援頁都只在 `PurrdrLinks` 填一次(付費牆共用;`PurrdrLinksTests` 核對字面值)。
enum AppStoreConfiguration {
    static let settingsLinks = SettingsLinks(
        appStoreID: PurrdrLinks.appStoreID,
        support: PurrdrLinks.support,
        privacyPolicy: PurrdrLinks.privacyPolicy
    )
}
