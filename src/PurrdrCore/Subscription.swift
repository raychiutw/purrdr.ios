import Foundation

/// 會員的訂閱(GLOSSARY):Purrdr Plus,開通推播與主機同步。權限記在會員身上，由 Purrdr 後台判定。
public struct MemberSubscription: Equatable, Sendable {
    public enum Status: String, Sendable {
        case active
        /// 扣款失敗、Apple 還在重試的帳單寬限期:仍有權限。
        case inGracePeriod = "in_grace_period"
        case expired
        /// 退款或撤銷。後台對外把帳單重試期(`billing_retry`)也當作已到期,沒有權限(#455)。
        case revoked
    }

    /// 來源商店(ADR-0007)。
    public enum Store: String, Sendable {
        case appStore = "app_store"
        case googlePlay = "google_play"
    }

    public var status: Status
    public var store: Store
    public var productID: String
    public var expiresAt: Date
    public var gracePeriodExpiresAt: Date?
    /// 到期後是否自動續訂;後台還不知道時是 `nil`。
    public var willAutoRenew: Bool?
    /// 升級合併時兩邊都有有效訂閱、沒保留的那一個:帳號頁提示使用者到商店取消,避免重複付費(後台 `pending_review`)。
    public var pendingReview: Bool

    public init(
        status: Status, store: Store, productID: String, expiresAt: Date,
        gracePeriodExpiresAt: Date? = nil, willAutoRenew: Bool? = nil, pendingReview: Bool = false
    ) {
        self.status = status
        self.store = store
        self.productID = productID
        self.expiresAt = expiresAt
        self.gracePeriodExpiresAt = gracePeriodExpiresAt
        self.willAutoRenew = willAutoRenew
        self.pendingReview = pendingReview
    }

    /// 有 Purrdr Plus 權限(推播與主機同步可以用)。
    public var isActive: Bool {
        status == .active || status == .inGracePeriod
    }

    /// Purrdr Plus 的商品(App Store Connect、StoreKit 設定檔、後台 `PLUS_PRODUCT_IDS` 要一致)。
    public static let productIDs = ["com.raychiu.purrdr.plus.monthly", "com.raychiu.purrdr.plus.yearly"]
}
