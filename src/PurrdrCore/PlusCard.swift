import Foundation

/// 帳號頁 Purrdr Plus 卡的內容(#409、規格 #402 設計稿第 27 組):純邏輯,畫面只依它排版與取文字。
///
/// 輸入是後台判定的 `PlusStatus`、訂閱細節(續訂日、寬限期限)與兩個旗標;輸出是「這張卡是哪一種、有哪些按鈕」。
/// iOS 只販售 App Store 訂閱:Google Play 訂閱的會員有 Plus、卡片只顯示來源,不給購買、管理或外部連結。
public struct PlusCard: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 已開通(含 Google Play 來源)。`renewsAt` 是後台記的到期／續訂日。
        case active(source: MemberSubscription.Store, renewsAt: Date?)
        /// 還沒有訂閱。
        case notActivated
        /// 這個 Apple 帳號的訂閱屬於另一個會員;`canTransfer` 為 `false` 表示這個會員已佔著有效訂閱、不能轉移。
        case ownedByAnotherMember(maskedEmail: String?, canTransfer: Bool)
        /// 帳單寬限:仍有 Plus,`deadline` 是更新付款方式的期限。
        case billingGrace(source: MemberSubscription.Store, deadline: Date?)
        case expired(source: MemberSubscription.Store, endedAt: Date?)
        /// 連不上後台、也還沒讀到過訂閱。
        case unreachable
    }

    public enum Button: Equatable, Sendable {
        case activatePlus
        case restorePurchases
        case transferSubscription
        /// 帳單寬限:開系統的管理訂閱畫面更新付款方式。
        case updatePaymentMethod
        /// 已到期:重新訂閱(開付費牆)。
        case renew
        case retry
    }

    public let kind: Kind
    /// 主要按鈕(實心);沒有時是 `nil`。
    public let primary: Button?
    /// 次要按鈕(純文字)。
    public let secondary: Button?
    /// 系統的管理訂閱(取消、變更方案):只有 App Store 訂閱有,樣式是淡色(tinted)。
    public let manage: AccountAction?
    /// 顯示的是上次讀到的資料(暫時連不上)。
    public let isStale: Bool
    /// 升級合併後沒保留的訂閱:提示到商店取消,避免重複付費。
    public let needsPendingReviewNotice: Bool

    /// - Parameters:
    ///   - canTransfer: 訂閱屬於其他會員時,後台回報目前會員沒有佔著有效訂閱名額。
    ///   - isStale: `subscription` 是上次讀到的(這一次連不上)。
    public init(plus: PlusStatus, subscription: MemberSubscription?, canTransfer: Bool = true, isStale: Bool = false) {
        self.isStale = isStale
        needsPendingReviewNotice = subscription?.pendingReview == true
        switch plus {
        case .active(let source):
            kind = .active(source: source, renewsAt: subscription?.expiresAt)
            primary = nil
            secondary = nil
            manage = source == .appStore ? .manageSubscription : nil
        case .none:
            kind = .notActivated
            primary = .activatePlus
            secondary = .restorePurchases
            manage = nil
        case .ownedByAnotherMember(let maskedEmail):
            kind = .ownedByAnotherMember(maskedEmail: maskedEmail, canTransfer: canTransfer)
            primary = canTransfer ? .transferSubscription : nil
            secondary = .restorePurchases
            manage = nil
        case .billingGrace(let source):
            kind = .billingGrace(source: source, deadline: subscription?.gracePeriodExpiresAt ?? subscription?.expiresAt)
            primary = source == .appStore ? .updatePaymentMethod : nil
            secondary = nil
            manage = nil
        case .expired(let source):
            kind = .expired(source: source, endedAt: subscription?.expiresAt)
            primary = .renew
            secondary = .restorePurchases
            manage = nil
        case .unreachable:
            kind = .unreachable
            primary = .retry
            secondary = nil
            manage = nil
        }
    }
}
