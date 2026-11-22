import Foundation
import PurrdrCore
import Testing

/// 刪除會員前要不要先處理訂閱(#412、App Store 審查準則 5.1.1(v)):刪會員不會取消商店訂閱,會繼續扣款的才要說明。
@Suite("刪除會員前的訂閱說明")
struct DeletionSubscriptionNoticeTests {
    private func subscription(_ status: MemberSubscription.Status, store: MemberSubscription.Store) -> MemberSubscription {
        MemberSubscription(status: status, store: store, productID: "com.raychiu.purrdr.plus.monthly", expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("沒有訂閱:不需要先處理")
    func none() {
        #expect(DeletionSubscriptionNotice(subscription: nil) == nil)
    }

    @Test("App Store 訂閱仍會扣款(生效中、寬限期):先處理 App Store")
    func appStoreStillBilling() {
        for status in [MemberSubscription.Status.active, .inGracePeriod] {
            #expect(DeletionSubscriptionNotice(subscription: subscription(status, store: .appStore)) == .appStore, "\(status)")
        }
    }

    @Test("Google Play 訂閱仍會扣款:只給文字指引")
    func googlePlayStillBilling() {
        #expect(DeletionSubscriptionNotice(subscription: subscription(.active, store: .googlePlay)) == .googlePlay)
    }

    @Test("已到期或已退款:不會再扣款,不需要先處理")
    func notBilling() {
        for status in [MemberSubscription.Status.expired, .revoked] {
            #expect(DeletionSubscriptionNotice(subscription: subscription(status, store: .appStore)) == nil, "\(status)")
        }
    }

    @Test("已關閉自動續訂的生效中訂閱:仍提醒(使用者可能想先處理)")
    func autoRenewOffStillMentioned() {
        var sub = subscription(.active, store: .appStore)
        sub.willAutoRenew = false
        #expect(DeletionSubscriptionNotice(subscription: sub) == .appStore)
    }
}
