import Foundation
import PurrdrFeatures
import Testing

/// 付費牆與設定頁的對外連結(#36 上架準備)。
///
/// 網址要跟 App Store Connect 填的、`docs/site/purrdr/` 發佈出去的網頁一致，所以以字面值核對，
/// 不從程式組出來。
@Suite("對外連結")
struct PurrdrLinksTests {
    @Test("隱私權政策與支援頁在 raychiutw.github.io/purrdr/")
    func websitePages() {
        #expect(PurrdrLinks.privacyPolicy.absoluteString == "https://raychiutw.github.io/purrdr/privacy/")
        #expect(PurrdrLinks.support.absoluteString == "https://raychiutw.github.io/purrdr/support/")
    }

    @Test("使用條款是 Apple 標準 EULA")
    func termsOfUse() {
        #expect(PurrdrLinks.termsOfUse.absoluteString == "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    }

    @Test("沒有佔位網址")
    func noPlaceholders() {
        for url in [PurrdrLinks.privacyPolicy, PurrdrLinks.support, PurrdrLinks.termsOfUse] {
            #expect(url.scheme == "https", "\(url)")
            #expect(!(url.host() ?? "").hasSuffix(".invalid"), "\(url)")
            #expect(!url.absoluteString.uppercased().contains("REPLACE"), "\(url)")
        }
    }
}

/// App Store id 與評分連結(#36:App Store Connect 已建立 app)。
@Suite("App Store 連結")
struct AppStoreLinkTests {
    @Test("App Store id 是 App Store Connect 的 Apple ID")
    func appStoreID() {
        #expect(PurrdrLinks.appStoreID == "6835416115")
    }

    @Test("為 Purrdr 評分打開 App Store 的撰寫評論頁")
    func writeReview() {
        let links = SettingsLinks(
            appStoreID: PurrdrLinks.appStoreID, support: PurrdrLinks.support, privacyPolicy: PurrdrLinks.privacyPolicy)
        #expect(links.writeReview.absoluteString == "https://apps.apple.com/app/id6835416115?action=write-review")
    }
}
