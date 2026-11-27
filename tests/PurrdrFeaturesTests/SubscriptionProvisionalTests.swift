import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 購買與恢復的先行生效與後台覆蓋(#413):後台確認前依 StoreKit 權限先讓 Plus 生效,後台回來後以後台為準;
/// 後台回「已有有效訂閱」(`subscription_already_active`)時不能再購買。後台回應依 `raychiutw/purrdr.server` 的 `README.md`。
@MainActor
@Suite("訂閱先行生效與覆蓋")
struct SubscriptionProvisionalTests {
    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let store = FakePlusStore()
    static let member = Member(id: "6f1c2b0e-5d4a-4c7e-9a7b-3e2f1d0c9b8a", identities: [])
    static let transaction = PlusTransaction(id: 7, signedTransaction: "jws-7")

    func makeModel() -> SubscriptionModel {
        SubscriptionModel(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            store: store)
    }

    func signIn() throws {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
    }

    @Test("購買後連不上後台:依 StoreKit 權限先讓 Plus 生效(標成尚未由後台確認),交易留著不 finish")
    func purchaseIsProvisionalWhenBackendUnreachable() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .unreachable)
        store.purchaseOutcome = .purchased(Self.transaction)
        let model = makeModel()

        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        #expect(model.isPlusActive)
        #expect(model.isPlusProvisional)
        #expect(model.plusStatus == .active(source: .appStore))
        #expect(model.notice == .purchaseNotDelivered)
        #expect(store.finished.isEmpty)
    }

    @Test("後台確認後以後台為準:先行生效的標記消失,訂閱是後台回的那筆")
    func backendConfirmationReplacesProvisional() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .unreachable, .json(200, SubscriptionReplies.active))
        store.purchaseOutcome = .purchased(Self.transaction)
        let model = makeModel()
        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        await model.handle(Self.transaction)

        #expect(!model.isPlusProvisional)
        #expect(model.subscription?.status == .active)
        #expect(model.isPlusActive)
        #expect(store.finished == [7])
    }

    @Test("後台說這個訂閱屬於其他會員:先行生效被覆蓋,Plus 關閉並顯示轉移")
    func backendOwnedByAnotherMemberOverridesProvisional() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .unreachable, .json(409, SubscriptionOwnershipTests.inUse))
        store.purchaseOutcome = .purchased(Self.transaction)
        let model = makeModel()
        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        await model.handle(Self.transaction)

        #expect(!model.isPlusProvisional)
        #expect(!model.isPlusActive)
        #expect(model.plusStatus == .ownedByAnotherMember(maskedEmail: "r***@example.net"))
    }

    @Test("後台讀到訂閱狀態(沒有訂閱)就以後台為準,清掉先行生效")
    func refreshClearsProvisional() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .unreachable)
        backend.on("GET", "/v1/members/me/subscription", .json(200, #"{"subscription":null}"#))
        store.purchaseOutcome = .purchased(Self.transaction)
        let model = makeModel()
        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        await model.refresh()

        #expect(!model.isPlusProvisional)
        #expect(!model.isPlusActive)
    }

    @Test("後台連不上時重新整理:保留先行生效")
    func unreachableRefreshKeepsProvisional() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .unreachable)
        backend.on("GET", "/v1/members/me/subscription", .json(503, Replies.error("store_unavailable")))
        store.purchaseOutcome = .purchased(Self.transaction)
        let model = makeModel()
        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        await model.refresh()

        #expect(model.isPlusProvisional)
        #expect(model.isPlusActive)
    }

    @Test("恢復購買連不上後台:有 StoreKit 權限就先讓 Plus 生效")
    func restoreIsProvisionalWhenBackendUnreachable() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .unreachable)
        store.current = [Self.transaction]
        let model = makeModel()

        await model.restore()

        #expect(model.isPlusActive)
        #expect(model.isPlusProvisional)
    }

    @Test("沒登入時不先行生效:StoreKit 的權限不能讓沒有會員的人開通知與同步")
    func noProvisionalWhenSignedOut() async throws {
        store.current = [Self.transaction]
        let model = makeModel()

        await model.restore()

        #expect(!model.isPlusActive)
        #expect(!model.isPlusProvisional)
        #expect(model.notice == .signInRequired)
    }

    @Test("購買時後台回已有有效訂閱:提示不能再購買,不先行生效,交易 finish(重送也不會成功)")
    func purchaseRejectedAsAlreadyActive() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(409, Replies.error("subscription_already_active")))
        store.purchaseOutcome = .purchased(Self.transaction)
        let model = makeModel()

        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        #expect(model.notice == .alreadySubscribed)
        #expect(!model.isPlusProvisional)
        #expect(store.finished == [7])
    }

    @Test("已有後台確認的有效訂閱:不再開 StoreKit 購買畫面")
    func noPurchaseWhileActive() async throws {
        try signIn()
        backend.on("GET", "/v1/members/me/subscription", .json(200, SubscriptionReplies.active))
        let model = makeModel()
        await model.refresh()

        await model.purchase(planID: FakePlusStore.yearly.id, member: Self.member)

        #expect(store.purchases.isEmpty)
        #expect(model.notice == .alreadySubscribed)
    }

    @Test("帳單重試期仍佔一會員一訂閱的名額:不開 StoreKit 購買畫面,但仍沒有 Plus 權限(#462)")
    func noPurchaseWhileBillingRetry() async throws {
        try signIn()
        backend.on("GET", "/v1/members/me/subscription", .json(200, #"{"subscription":{"status":"expired","store":"app_store","productId":"p","expiresAt":"2026-11-01T00:00:00.000Z","billingRetry":true}}"#))
        let model = makeModel()
        await model.refresh()

        await model.purchase(planID: FakePlusStore.yearly.id, member: Self.member)

        #expect(model.subscription?.billingRetry == true)
        #expect(!model.isPlusActive)
        #expect(store.purchases.isEmpty)
        #expect(model.notice == .alreadySubscribed)
    }

    @Test("已到期且沒有 billingRetry(缺欄位):可以再購買")
    func purchaseAllowedWhenExpiredWithoutBillingRetry() async throws {
        try signIn()
        backend.on("GET", "/v1/members/me/subscription", .json(200, #"{"subscription":{"status":"expired","store":"app_store","productId":"p","expiresAt":"2026-11-01T00:00:00.000Z"}}"#))
        store.purchaseOutcome = .canceled
        let model = makeModel()
        await model.refresh()

        await model.purchase(planID: FakePlusStore.yearly.id, member: Self.member)

        #expect(model.subscription?.billingRetry == false)
        #expect(store.purchases.count == 1)
    }

    @Test("帳單重試期恢復購買:不送交易,提示已有訂閱")
    func restoreWhileBillingRetry() async throws {
        try signIn()
        backend.on("GET", "/v1/members/me/subscription", .json(200, #"{"subscription":{"status":"expired","store":"app_store","productId":"p","expiresAt":"2026-11-01T00:00:00.000Z","billingRetry":true}}"#))
        store.current = [Self.transaction]
        let model = makeModel()
        await model.refresh()

        await model.restore()

        #expect(model.notice == .alreadySubscribed)
        #expect(store.finished.isEmpty)
    }

    @Test("轉移時後台說這個訂閱沒登記在任何會員:改走一般綁定")
    func transferFallsBackToBindingWhenNotRegistered() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(409, SubscriptionOwnershipTests.inUse), .json(200, SubscriptionReplies.active))
        backend.on("POST", "/v1/members/me/subscription/transfer", .json(404, Replies.error("subscription_not_found")))
        store.current = [Self.transaction]
        let model = makeModel()
        await model.restore()

        await model.transferSubscription()

        #expect(model.isPlusActive)
        #expect(!model.isPlusProvisional)
        #expect(model.plusStatus == .active(source: .appStore))
    }
}
