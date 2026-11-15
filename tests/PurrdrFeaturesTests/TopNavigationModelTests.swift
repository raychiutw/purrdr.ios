import Foundation
import PurrdrFeatures
import Testing

@MainActor
@Suite("iPhone 頂層導覽")
struct TopNavigationModelTests {
    @Test("深層連結 purrdr://settings 開啟設定 sheet")
    func settingsDeepLinkOpensSettings() throws {
        let model = TopNavigationModel()

        let handled = model.open(try #require(URL(string: "purrdr://settings")))

        #expect(handled)
        #expect(model.sheet == .settings)
    }

    @Test(
        "不認得的連結不改變畫面，開著的主機 sheet 保持不動",
        arguments: ["purrdr://unknown", "https://settings", "otherapp://settings", "purrdr:settings"]
    )
    func unknownLinkKeepsCurrentSheet(link: String) throws {
        let model = TopNavigationModel()
        model.sheet = .hosts

        let handled = model.open(try #require(URL(string: link)))

        #expect(!handled)
        #expect(model.sheet == .hosts)
    }
}
