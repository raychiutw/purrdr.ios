import Foundation
import PurrdrCore
import Testing

/// 帳號頁 Purrdr Plus 卡的內容(#409、規格 #402 設計稿第 27 組):每個狀態的種類、按鈕與是否為上次資料。
@Suite("Plus 卡")
struct PlusCardTests {
    private let renewal = Date(timeIntervalSince1970: 1_800_000_000)

    private func subscription(
        _ status: MemberSubscription.Status, store: MemberSubscription.Store = .appStore, pendingReview: Bool = false
    ) -> MemberSubscription {
        MemberSubscription(
            status: status, store: store, productID: "yearly", expiresAt: renewal, gracePeriodExpiresAt: renewal,
            willAutoRenew: true, pendingReview: pendingReview)
    }

    private func card(_ plus: PlusStatus, subscription: MemberSubscription? = nil, canTransfer: Bool = true, isStale: Bool = false) -> PlusCard {
        PlusCard(plus: plus, subscription: subscription, canTransfer: canTransfer, isStale: isStale)
    }

    @Test("有 Plus(App Store):只有「管理訂閱」,沒有購買按鈕")
    func activeAppStore() {
        let card = card(.active(source: .appStore), subscription: subscription(.active))

        #expect(card.kind == .active(source: .appStore, renewsAt: renewal))
        #expect(card.primary == nil)
        #expect(card.manage == .manageSubscription)
        #expect(card.secondary == nil)
    }

    @Test("沒有 Plus:主按鈕開通、次按鈕恢復購買")
    func notActivated() {
        let card = card(.none)

        #expect(card.kind == .notActivated)
        #expect(card.primary == .activatePlus)
        #expect(card.secondary == .restorePurchases)
        #expect(card.manage == nil)
    }

    @Test("Google Play 訂閱:顯示來源,iOS 沒有購買、管理或外部連結")
    func googlePlay() {
        let card = card(.active(source: .googlePlay), subscription: subscription(.active, store: .googlePlay))

        #expect(card.kind == .active(source: .googlePlay, renewsAt: renewal))
        #expect(card.primary == nil)
        #expect(card.secondary == nil)
        #expect(card.manage == nil)
    }

    @Test("訂閱屬於其他會員且可轉移:主按鈕轉移、次按鈕恢復購買")
    func ownedByAnotherMember() {
        let card = card(.ownedByAnotherMember(maskedEmail: "r***@icloud.com"))

        #expect(card.kind == .ownedByAnotherMember(maskedEmail: "r***@icloud.com", canTransfer: true))
        #expect(card.primary == .transferSubscription)
        #expect(card.secondary == .restorePurchases)
    }

    @Test("訂閱屬於其他會員但這個會員已有訂閱:不能轉移,只說明")
    func ownedByAnotherMemberCannotTransfer() {
        let card = card(.ownedByAnotherMember(maskedEmail: nil), canTransfer: false)

        #expect(card.kind == .ownedByAnotherMember(maskedEmail: nil, canTransfer: false))
        #expect(card.primary == nil)
    }

    @Test("帳單寬限:仍有 Plus,主按鈕更新付款方式")
    func billingGrace() {
        let card = card(.billingGrace(source: .appStore), subscription: subscription(.inGracePeriod))

        #expect(card.kind == .billingGrace(source: .appStore, deadline: renewal))
        #expect(card.primary == .updatePaymentMethod)
        #expect(card.manage == nil)
    }

    @Test("已到期:主按鈕續訂、次按鈕恢復購買")
    func expired() {
        let card = card(.expired(source: .appStore), subscription: subscription(.expired))

        #expect(card.kind == .expired(source: .appStore, endedAt: renewal))
        #expect(card.primary == .renew)
        #expect(card.secondary == .restorePurchases)
    }

    @Test("暫時連不上、沒有上次資料:只能重試")
    func unreachableWithoutData() {
        let card = card(.unreachable)

        #expect(card.kind == .unreachable)
        #expect(card.primary == .retry)
    }

    @Test("暫時連不上但有上次資料:照上次的狀態顯示並標成上次資料")
    func staleKeepsLastKnown() {
        let card = card(.active(source: .appStore), subscription: subscription(.active), isStale: true)

        #expect(card.kind == .active(source: .appStore, renewsAt: renewal))
        #expect(card.isStale)
    }

    @Test("升級後待處理的訂閱(兩邊都有訂閱時沒保留的那個)要提示處理")
    func pendingReview() {
        let pending = card(.active(source: .appStore), subscription: subscription(.active, store: .googlePlay, pendingReview: true))
        let normal = card(.active(source: .appStore), subscription: subscription(.active))

        #expect(pending.needsPendingReviewNotice)
        #expect(!normal.needsPendingReviewNotice)
    }
}
