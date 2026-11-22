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
        #expect(PurrdrLinks.hostServiceGuide.absoluteString == "https://raychiutw.github.io/purrdr/host-service/")
    }

    @Test("配對頁的完整說明連到主機服務網頁的配對一節(繁中與英文各有錨點,網頁上也要有)")
    func hostServicePairingAnchors() throws {
        #expect(PurrdrLinks.hostServicePairing(prefersChinese: true).absoluteString == "https://raychiutw.github.io/purrdr/host-service/#pair")
        #expect(PurrdrLinks.hostServicePairing(prefersChinese: false).absoluteString == "https://raychiutw.github.io/purrdr/host-service/#pair-en")
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) { root.deleteLastPathComponent() }
        let html = try String(contentsOf: root.appending(path: "docs/site/purrdr/host-service/index.html"), encoding: .utf8)
        #expect(html.contains("id=\"pair\""))
        #expect(html.contains("id=\"pair-en\""))
    }

    @Test("使用條款是 Apple 標準 EULA")
    func termsOfUse() {
        #expect(PurrdrLinks.termsOfUse.absoluteString == "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    }

    @Test("沒有佔位網址")
    func noPlaceholders() {
        for url in [PurrdrLinks.privacyPolicy, PurrdrLinks.support, PurrdrLinks.termsOfUse, PurrdrLinks.hostServiceGuide] {
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
