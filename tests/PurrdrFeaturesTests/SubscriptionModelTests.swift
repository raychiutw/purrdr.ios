import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 訂閱 Purrdr Plus 的 model(Seam 2:後台用 `HTTPStub`;Seam 3:StoreKit 用記憶體內的 `FakePlusStore`)。
///
/// 後台回應依 `raychiutw/purrdr.server` 的 `README.md` 的 API 契約手寫。StoreKit 真正的商品與購買由 UI 測試以 StoreKit 設定檔
/// (`src/App/Purrdr.storekit`)驗證;`SKTestSession` 需要 app 宿主，`swift test` 跑不了。
@MainActor
@Suite("訂閱")
struct SubscriptionModelTests {
    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let store = FakePlusStore()
    static let memberID = "6f1c2b0e-5d4a-4c7e-9a7b-3e2f1d0c9b8a"
    static let member = Member(id: memberID, identities: [])

    func makeModel() -> SubscriptionModel {
        SubscriptionModel(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            store: store
        )
    }

    /// 已登入的會員(更新權杖在 Keychain,後台換得到存取權杖)。
    func signIn() throws {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
    }

    // MARK: - 付費牆

    @Test("付費牆顯示 StoreKit 的方案(年繳在前、月繳在後),預設選年繳")
    func loadsPlans() async {
        store.plans = [FakePlusStore.monthly, FakePlusStore.yearly]
        let model = makeModel()

        await model.loadPlans()

        #expect(model.plans == [FakePlusStore.yearly, FakePlusStore.monthly])
        #expect(model.defaultPlan == FakePlusStore.yearly)
        #expect(model.storefront == .available)
    }

    @Test("只有月繳可用時,預設方案是月繳")
    func defaultPlanFallsBackToMonthly() async {
        store.plans = [FakePlusStore.monthly]
        let model = makeModel()

        await model.loadPlans()

        #expect(model.defaultPlan == FakePlusStore.monthly)
    }

    @Test("商品順序:年繳在前")
    func productOrderYearlyFirst() {
        #expect(MemberSubscription.productIDs == ["com.raychiu.purrdr.plus.yearly", "com.raychiu.purrdr.plus.monthly"])
    }

    @Test("不能付款(例如螢幕使用時間限制)時不顯示商店")
    func paymentsDisabled() async {
        store.plans = [FakePlusStore.monthly]
        store.canMakePayments = false
        let model = makeModel()

        await model.loadPlans()

        #expect(model.storefront == .paymentsDisabled)
    }

    @Test("讀不到商品時提示，可以重試")
    func plansUnavailable() async {
        store.plansError = true
        let model = makeModel()

        await model.loadPlans()

        #expect(model.storefront == .unavailable)
        #expect(model.plans.isEmpty)
    }

    // MARK: - 購買

    @Test("購買：以會員 ID 當 appAccountToken,交易送到後台成功後才 finish,訂閱生效並歡迎")
    func purchase() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(200, SubscriptionReplies.active))
        store.purchaseOutcome = .purchased(PlusTransaction(id: 7, signedTransaction: "jws-7"))
        let model = makeModel()

        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        #expect(store.purchases.map(\.planID) == [FakePlusStore.monthly.id])
        #expect(store.purchases.first?.appAccountToken == UUID(uuidString: Self.memberID))
        let submitted = try #require(backend.requests(to: "/v1/members/me/subscription/app-store").first)
        #expect(submitted.json?["signedTransaction"] as? String == "jws-7")
        #expect(submitted.authorization == "Bearer access-1")
        #expect(store.finished == [7])
        #expect(model.subscription?.status == .active)
        #expect(model.isPlusActive)
        #expect(model.notice == .welcome)
    }

    @Test("購買後連不上後台：不 finish(StoreKit 下次啟動會再給)、提示")
    func purchaseWhileBackendUnreachable() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .unreachable)
        store.purchaseOutcome = .purchased(PlusTransaction(id: 7, signedTransaction: "jws-7"))
        let model = makeModel()

        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        #expect(store.finished.isEmpty)
        #expect(model.isPlusProvisional)  // 後台確認前依 StoreKit 先行生效(#413)
        #expect(model.subscription == nil)
        #expect(model.notice == .purchaseNotDelivered)
    }

    @Test("使用者在系統購買畫面取消：不送後台、不提示")
    func purchaseCanceled() async throws {
        try signIn()
        store.purchaseOutcome = .canceled
        let model = makeModel()

        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        #expect(backend.requests(to: "/v1/members/me/subscription/app-store").isEmpty)
        #expect(model.notice == nil)
    }

    @Test("等待家長同意(Ask to Buy):提示等候，不送後台")
    func purchasePending() async throws {
        try signIn()
        store.purchaseOutcome = .pending
        let model = makeModel()

        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        #expect(backend.requests(to: "/v1/members/me/subscription/app-store").isEmpty)
        #expect(model.notice == .pending)
    }

    @Test("訂閱已屬於另一個會員：提示並 finish(重送也不會成功)")
    func subscriptionInUse() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(409, Replies.error("subscription_in_use")))
        store.purchaseOutcome = .purchased(PlusTransaction(id: 7, signedTransaction: "jws-7"))
        let model = makeModel()

        await model.purchase(planID: FakePlusStore.monthly.id, member: Self.member)

        #expect(model.notice == .inUseByAnotherMember)
        #expect(store.finished == [7])
        #expect(!model.isPlusActive)
    }

    // MARK: - 恢復購買與兌換

    @Test("恢復購買：先跟 App Store 同步，再把目前有效的交易送到後台")
    func restore() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(200, SubscriptionReplies.active))
        store.current = [PlusTransaction(id: 3, signedTransaction: "jws-3")]
        let model = makeModel()

        await model.restore()

        #expect(store.syncCount == 1)
        #expect(backend.requests(to: "/v1/members/me/subscription/app-store").first?.json?["signedTransaction"] as? String == "jws-3")
        #expect(model.isPlusActive)
        #expect(model.notice == .restored)
    }

    @Test("恢復購買但沒有可恢復的訂閱：照實提示")
    func restoreNothing() async throws {
        try signIn()
        backend.on("GET", "/v1/members/me/subscription", .json(200, #"{"subscription": null}"#))
        let model = makeModel()

        await model.restore()

        #expect(backend.requests(to: "/v1/members/me/subscription/app-store").isEmpty)
        #expect(model.notice == .nothingToRestore)
    }

    @Test("兌換 Offer Code 後，交易經交易更新送到後台並 finish")
    func offerCodeRedeemedThroughUpdates() async throws {
        try signIn()
        backend.on("POST", "/v1/members/me/subscription/app-store", .json(200, SubscriptionReplies.active))
        let model = makeModel()
        let observing = Task { await model.observeTransactionUpdates() }

        store.deliverUpdate(PlusTransaction(id: 9, signedTransaction: "jws-offer"))
        try await waitUntil { store.finished == [9] }
        observing.cancel()

        #expect(backend.requests(to: "/v1/members/me/subscription/app-store").first?.json?["signedTransaction"] as? String == "jws-offer")
        #expect(model.isPlusActive)
    }

    @Test("沒登入時收到交易更新：不 finish,等登入後再送")
    func updateWhileSignedOut() async throws {
        let model = makeModel()

        await model.handle(PlusTransaction(id: 9, signedTransaction: "jws-9"))

        #expect(store.finished.isEmpty)
        #expect(backend.requests.isEmpty)
    }

    // MARK: - 訂閱狀態

    @Test("讀取訂閱狀態：有效")
    func refreshActive() async throws {
        try signIn()
        backend.on("GET", "/v1/members/me/subscription", .json(200, SubscriptionReplies.active))
        let model = makeModel()

        await model.refresh()

        let subscription = try #require(model.subscription)
        #expect(subscription.status == .active)
        #expect(subscription.store == .appStore)
        #expect(subscription.productID == "com.raychiu.purrdr.plus.monthly")
        #expect(subscription.expiresAt == Date(timeIntervalSince1970: 1_796_342_400))
        #expect(subscription.willAutoRenew == true)
        #expect(model.isPlusActive)
        #expect(!model.needsRenewal)
    }

    @Test("到期或退款後：Purrdr Plus 停用(推播與主機同步看 isPlusActive),並提示續訂")
    func refreshEnded() async throws {
        try signIn()
        backend.on(
            "GET", "/v1/members/me/subscription",
            .json(200, SubscriptionReplies.with(status: "expired")),
            .json(200, SubscriptionReplies.with(status: "revoked"))
        )
        let model = makeModel()

        await model.refresh()
        #expect(model.subscription?.status == .expired)
        #expect(!model.isPlusActive)
        #expect(model.needsRenewal)

        await model.refresh()
        #expect(model.subscription?.status == .revoked)
        #expect(!model.isPlusActive)
        #expect(model.needsRenewal)
    }

    @Test("帳單寬限期內仍有 Purrdr Plus")
    func gracePeriod() async throws {
        try signIn()
        backend.on("GET", "/v1/members/me/subscription", .json(200, SubscriptionReplies.with(status: "in_grace_period")))
        let model = makeModel()

        await model.refresh()

        #expect(model.isPlusActive)
        #expect(!model.needsRenewal)
    }

    @Test("沒登入時沒有訂閱，也不提示續訂、不連後台")
    func refreshSignedOut() async {
        let model = makeModel()

        await model.refresh()

        #expect(model.subscription == nil)
        #expect(!model.isPlusActive)
        #expect(!model.needsRenewal)
        #expect(backend.requests.isEmpty)
    }

    /// 等到條件成立(上限 `asyncWaitLimit`;條件一成立就返回)。
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + asyncWaitLimit
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

enum SubscriptionReplies {
    static let member = #"{"id": "6f1c2b0e-5d4a-4c7e-9a7b-3e2f1d0c9b8a", "identities": []}"#

    static let active = with(status: "active")

    static func with(status: String) -> String {
        #"""
        {"subscription": {"status": "\#(status)", "store": "app_store", "productId": "com.raychiu.purrdr.plus.monthly",
          "expiresAt": "2026-12-04T00:00:00.000Z", "gracePeriodExpiresAt": null, "willAutoRenew": true}}
        """#
    }
}
