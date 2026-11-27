import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 帳號頁 Plus 卡背後的狀態(#409):訂閱屬於其他會員時的轉移、暫時連不上時的上次資料、Face ID 確認。
/// 後台回應依 `raychiutw/purrdr.server` 的 `README.md`(「訂閱綁定與 App Store 串接」「訂閱轉移」)。
@MainActor
@Suite("訂閱歸屬與轉移")
struct SubscriptionOwnershipTests {
    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let store = FakePlusStore()

    static let inUse = #"{"error":{"code":"subscription_in_use","message":"in use","details":{"ownerEmail":"r***@example.net","canTransfer":true}}}"#
    static let inUseCannotTransfer = #"{"error":{"code":"subscription_in_use","message":"in use","details":{"ownerEmail":null,"canTransfer":false}}}"#
    static let transferred =
        #"{"subscription":{"status":"active","store":"app_store","productId":"com.raychiu.purrdr.plus.yearly","expiresAt":"2026-12-04T00:00:00.000Z","gracePeriodExpiresAt":null,"willAutoRenew":true},"appAccountTokenUpdated":true}"#

    /// `confirmOwner` 回傳要答的驗證結果;`confirmations` 記下被問了幾次。
    final class Owner {
        var allows = true
        var confirmations = 0
    }

    func makeModel(owner: Owner? = nil) -> SubscriptionModel {
        let session = MemberSession(
            transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens)
        guard let owner else { return SubscriptionModel(session: session, store: store) }
        return SubscriptionModel(session: session, store: store, confirmOwner: {
            owner.confirmations += 1
            return owner.allows
        })
    }

    func signIn() throws {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
    }

    @Test("恢復購買時訂閱屬於另一個會員:Plus 卡顯示遮蔽 email 與轉移選項,而不是「未開通」")
    func restoreShowsOwnedByAnotherMember() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(409, Self.inUse))
        store.current = [PlusTransaction(id: 5, signedTransaction: "jws-5")]
        let model = makeModel()

        await model.restore()

        #expect(model.plusStatus == .ownedByAnotherMember(maskedEmail: "r***@example.net"))
        #expect(model.plusCard.primary == .transferSubscription)
        #expect(!model.isPlusActive)
    }

    @Test("轉移:先確認是本人,再把簽章交易交給後台,成功後 Plus 立即生效")
    func transfer() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(409, Self.inUse))
        backend.on("POST", "/v1/members/me/subscription/transfer", .json(200, Self.transferred))
        store.current = [PlusTransaction(id: 5, signedTransaction: "jws-5")]
        let owner = Owner()
        let model = makeModel(owner: owner)
        await model.restore()

        await model.transferSubscription()

        #expect(owner.confirmations == 1)
        #expect(backend.requests(to: "/v1/members/me/subscription/transfer").first?.json?["signedTransaction"] as? String == "jws-5")
        #expect(model.isPlusActive)
        #expect(model.plusStatus == .active(source: .appStore))
        #expect(model.notice == .transferred)
        #expect(store.finished.contains(5))
    }

    @Test("轉移沒通過本人確認:不送任何請求,仍顯示轉移選項")
    func transferNeedsOwnerConfirmation() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(409, Self.inUse))
        store.current = [PlusTransaction(id: 5, signedTransaction: "jws-5")]
        let owner = Owner()
        let model = makeModel(owner: owner)
        await model.restore()
        owner.allows = false

        await model.transferSubscription()

        #expect(backend.requests(to: "/v1/members/me/subscription/transfer").isEmpty)
        #expect(model.plusStatus == .ownedByAnotherMember(maskedEmail: "r***@example.net"))
    }

    @Test("這個會員已有有效訂閱:轉移被擋下並說明原因,Plus 維持原本的訂閱")
    func transferBlockedByActiveSubscription() async throws {
        try signIn()
        backend.on("GET", "/v1/members/me/subscription", .json(200, SubscriptionReplies.active))
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(409, Self.inUseCannotTransfer))
        store.current = [PlusTransaction(id: 5, signedTransaction: "jws-5")]
        let model = makeModel()
        await model.refresh()

        await model.restore()

        #expect(model.notice == .transferBlocked)
        #expect(model.plusStatus == .active(source: .appStore))
        #expect(model.plusCard.primary == nil)
    }

    @Test("後台說已有有效訂閱(subscription_already_active):提示轉移被擋下")
    func transferRejectedAsAlreadyActive() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(409, Self.inUse))
        backend.on("POST", "/v1/members/me/subscription/transfer", .json(409, Replies.error("subscription_already_active")))
        store.current = [PlusTransaction(id: 5, signedTransaction: "jws-5")]
        let model = makeModel()
        await model.restore()

        await model.transferSubscription()

        #expect(model.notice == .transferBlocked)
        #expect(!model.isPlusActive)
    }

    @Test("暫時連不上:保留上次的訂閱並標成上次資料,不變成未開通")
    func unreachableKeepsLastKnown() async throws {
        try signIn()
        backend.on("GET", "/v1/members/me/subscription", .json(200, SubscriptionReplies.active), .json(503, Replies.error("store_unavailable")))
        let model = makeModel()
        await model.refresh()

        await model.refresh()

        #expect(model.isStale)
        #expect(model.plusStatus == .active(source: .appStore))
        #expect(model.plusCard.isStale)
    }

    @Test("暫時連不上而且還沒讀到過:狀態是連不上,不是未開通")
    func unreachableWithoutData() async throws {
        try signIn()
        backend.on("GET", "/v1/members/me/subscription", .json(503, Replies.error("store_unavailable")))
        let model = makeModel()

        await model.refresh()

        #expect(model.plusStatus == .unreachable)
        #expect(model.plusCard.primary == .retry)
    }

    @Test("讀到訂閱就清掉上次資料標記與轉移選項")
    func refreshClearsStaleAndOffer() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(409, Self.inUse))
        backend.on("GET", "/v1/members/me/subscription", .json(200, SubscriptionReplies.active))
        store.current = [PlusTransaction(id: 5, signedTransaction: "jws-5")]
        let model = makeModel()
        await model.restore()

        await model.refresh()

        #expect(!model.isStale)
        #expect(model.plusStatus == .active(source: .appStore))
    }

    @Test("後台對外沒有帳單重試期:billing_retry 當作已到期(沒有 Plus),待處理旗標讀得懂")
    func billingRetryAndPendingReview() async throws {
        try signIn()
        let body = #"{"subscription":{"status":"billing_retry","store":"google_play","productId":"p","expiresAt":"2026-12-04T00:00:00.000Z","pendingReview":true}}"#
        backend.on("GET", "/v1/members/me/subscription", .json(200, body))
        let model = makeModel()

        await model.refresh()

        #expect(model.subscription?.status == .expired)
        #expect(model.plusStatus == .expired(source: .googlePlay))
        #expect(model.subscription?.pendingReview == true)
        #expect(!model.isPlusActive)
        #expect(model.plusCard.needsPendingReviewNotice)
    }
}
