import Foundation
import PurrdrCore
import Testing

/// 帳號與 Plus 的狀態(#407、規格 #402):每個狀態的鎖定、完成與可用動作。
@Suite("帳號與 Plus 狀態")
struct AccountStateTests {
    private func state(_ authentication: AccountState.Authentication, _ plus: PlusStatus) -> AccountState {
        AccountState(authentication: authentication, plus: plus)
    }

    @Test("已登入、沒有 Plus(#675):通知可用、本機開著算完成;主機同步仍鎖住、不得算完成")
    func memberWithoutPlusKeepsNotificationsButNotSync() {
        let account = state(.signedIn, .none)

        #expect(account.isDone(.notifications, isOnLocally: true))
        #expect(!account.isDone(.hostSync, isOnLocally: true))
        #expect(account.availability(of: .notifications) == .available)
        #expect(account.availability(of: .hostSync) == .locked(.plusRequired))
    }

    @Test("未登入：選擇登入或加入；功能鎖住；殘留的 Plus 狀態不算")
    func signedOut() {
        let account = state(.signedOut, .active(source: .appStore))

        #expect(account.needsEntryChoice)
        #expect(!account.hasPlus)
        #expect(account.availability(of: .notifications) == .locked(.signInRequired))
        #expect(!account.isDone(.hostSync, isOnLocally: true))
        #expect(account.availableActions == [.signIn, .join])
    }

    @Test("還在確認登入：功能鎖住、沒有動作、不要求選擇")
    func unknown() {
        let account = state(.unknown, .none)

        #expect(!account.needsEntryChoice)
        #expect(account.availability(of: .notifications) == .locked(.checkingAccount))
        #expect(account.availableActions.isEmpty)
    }

    @Test("已登入無 Plus：可開通或恢復購買")
    func signedInWithoutPlus() {
        let account = state(.signedIn, .none)

        #expect(!account.needsEntryChoice)
        #expect(!account.hasPlus)
        #expect(!account.needsRenewal)
        #expect(account.availableActions == [.activatePlus, .restorePurchases])
    }

    @Test("已登入有 App Store Plus：功能可用、本機開著才算完成、可管理訂閱")
    func plusFromAppStore() {
        let account = state(.signedIn, .active(source: .appStore))

        #expect(account.hasPlus)
        #expect(account.plus.source == .appStore)
        #expect(account.availability(of: .notifications) == .available)
        #expect(account.isDone(.notifications, isOnLocally: true))
        #expect(!account.isDone(.hostSync, isOnLocally: false))
        #expect(account.availableActions == [.manageSubscription])
    }

    @Test("Google Play 訂閱：在 iPhone 照樣有 Plus，但沒有購買或管理動作")
    func plusFromGooglePlay() {
        for plus in [PlusStatus.active(source: .googlePlay), .billingGrace(source: .googlePlay)] {
            let account = state(.signedIn, plus)

            #expect(account.hasPlus)
            #expect(account.plus.source == .googlePlay)
            #expect(account.availableActions.isEmpty)
        }
    }

    @Test("帳單寬限：仍有 Plus，並提示更新付款方式；生效中不提示")
    func billingGrace() {
        for plus in [PlusStatus.billingGrace(source: .appStore)] {
            let account = state(.signedIn, plus)

            #expect(account.hasPlus)
            #expect(account.needsPaymentMethodUpdate)
            #expect(account.availability(of: .hostSync) == .available)
        }
        #expect(!state(.signedIn, .active(source: .appStore)).needsPaymentMethodUpdate)
    }

    @Test("已到期：功能鎖住並提示續訂，可再開通或恢復購買")
    func expired() {
        let account = state(.signedIn, .expired(source: .appStore))

        #expect(!account.hasPlus)
        #expect(account.needsRenewal)
        #expect(account.availability(of: .hostSync) == .locked(.subscriptionEnded))
        #expect(!account.isDone(.hostSync, isOnLocally: true))
        #expect(account.availability(of: .notifications) == .available)
        #expect(account.availableActions == [.activatePlus, .restorePurchases])
    }

    @Test("訂閱屬於其他會員：功能鎖住，只提供轉移，不顯示成「未開通」")
    func ownedByAnotherMember() {
        let account = state(.signedIn, .ownedByAnotherMember(maskedEmail: "r***@example.com"))

        #expect(!account.hasPlus)
        #expect(account.availability(of: .hostSync) == .locked(.subscriptionOwnedByAnotherMember))
        #expect(account.availableActions == [.transferSubscription])
    }

    @Test("暫時連不上：仍是已登入，功能先鎖住、只提供重試，不要求重新登入")
    func unreachable() {
        let account = state(.signedIn, .unreachable)

        #expect(account.isSignedIn)
        #expect(!account.needsEntryChoice)
        #expect(account.availability(of: .hostSync) == .locked(.temporarilyUnreachable))
        #expect(account.availableActions == [.retry])
    }

    @Test("後台的訂閱換成 Plus 狀態：寬限算有權限，到期與撤銷都算已到期，沒有訂閱是 none")
    func mappingFromSubscription() {
        func subscription(_ status: MemberSubscription.Status, store: MemberSubscription.Store = .appStore) -> MemberSubscription {
            MemberSubscription(status: status, store: store, productID: "plus", expiresAt: Date(timeIntervalSince1970: 0))
        }

        #expect(PlusStatus(subscription: nil) == .none)
        #expect(PlusStatus(subscription: subscription(.active)) == .active(source: .appStore))
        #expect(PlusStatus(subscription: subscription(.inGracePeriod, store: .googlePlay)) == .billingGrace(source: .googlePlay))
        #expect(PlusStatus(subscription: subscription(.expired)) == .expired(source: .appStore))
        #expect(PlusStatus(subscription: subscription(.revoked)) == .expired(source: .appStore))
    }
}
