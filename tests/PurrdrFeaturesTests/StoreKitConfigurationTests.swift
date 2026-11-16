import Foundation
import PurrdrCore
import Testing

/// StoreKit 設定檔 `src/App/Purrdr.storekit` 與程式、後台一致(商品 ID、期間、2 週免費試用、Offer Code)。
///
/// `SKTestSession` 需要 app 宿主，`swift test` 不能載入設定檔，所以直接讀 JSON 檢查內容。
@Suite("StoreKit 設定檔")
struct StoreKitConfigurationTests {
    struct Subscription {
        var productID: String
        var period: String
        var trialPeriod: String?
        var trialMode: String?
        var codeOffers: [[String: Any]]
        var displayName: String?
        var displayPrice: String?
    }

    func subscriptions() throws -> [Subscription] {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/App/Purrdr.storekit")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let groups = try #require(root["subscriptionGroups"] as? [[String: Any]])
        #expect(groups.count == 1, "Purrdr Plus 只有一個訂閱群組")
        return try #require(groups.first?["subscriptions"] as? [[String: Any]]).map { item in
            let intro = item["introductoryOffer"] as? [String: Any]
            let localization = (item["localizations"] as? [[String: Any]])?.first
            return Subscription(
                productID: item["productID"] as? String ?? "",
                period: item["recurringSubscriptionPeriod"] as? String ?? "",
                trialPeriod: intro?["subscriptionPeriod"] as? String,
                trialMode: intro?["paymentMode"] as? String,
                codeOffers: item["codeOffers"] as? [[String: Any]] ?? [],
                displayName: localization?["displayName"] as? String,
                displayPrice: item["displayPrice"] as? String
            )
        }
    }

    @Test("月繳與年繳，商品 ID 與程式(MemberSubscription.productIDs)相同")
    func products() throws {
        let subscriptions = try subscriptions()
        #expect(subscriptions.map(\.productID) == MemberSubscription.productIDs)
        #expect(subscriptions.map(\.period) == ["P1M", "P1Y"])
        #expect(subscriptions.map(\.displayName) == ["Purrdr Plus Monthly", "Purrdr Plus Yearly"])
    }

    @Test("新訂閱者 2 週免費試用")
    func freeTrial() throws {
        for subscription in try subscriptions() {
            #expect(subscription.trialPeriod == "P2W", "\(subscription.productID)")
            #expect(subscription.trialMode == "free", "\(subscription.productID)")
        }
    }

    @Test("價格與上架設定相同：月繳 US$4.99、年繳 US$39.99(docs/launch/subscriptions.md)")
    func prices() throws {
        #expect(try subscriptions().map(\.displayPrice) == ["4.99", "39.99"])
    }

    @Test("Offer Code 只有月繳一組：1 個月免費、限新訂閱者(docs/launch/subscriptions.md)")
    func offerCode() throws {
        let subscriptions = try subscriptions()
        #expect(subscriptions.map(\.codeOffers.count) == [1, 0])
        let offer = try #require(subscriptions.first?.codeOffers.first)
        #expect(offer["paymentMode"] as? String == "free")
        #expect(offer["subscriptionPeriod"] as? String == "P1M")
        #expect(offer["eligibility"] as? [String] == ["new"])
    }
}
