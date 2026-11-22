import Foundation

/// 刪除會員前要先說明的訂閱(#412、App Store 審查準則 5.1.1(v)):
/// 刪除會員不會取消商店訂閱,商店會繼續收費,所以有仍會扣款的訂閱時先處理訂閱、再進刪除確認。
public enum DeletionSubscriptionNotice: Equatable, Sendable {
    /// App Store 訂閱:說明 Apple 會繼續收費,提供「管理訂閱」(系統畫面)。
    case appStore
    /// Google Play 訂閱:只顯示文字指引(iOS 不放外部連結)。
    case googlePlay

    /// 沒有訂閱,或訂閱已到期、退款(不會再扣款)時是 `nil`:直接進刪除確認。
    public init?(subscription: MemberSubscription?) {
        guard let subscription else { return nil }
        // 生效中、寬限期與帳單重試期(`billingRetry`,#462)Apple 都還在扣款。
        guard subscription.isStillBilling else { return nil }
        switch subscription.store {
        case .appStore: self = .appStore
        case .googlePlay: self = .googlePlay
        }
    }
}
