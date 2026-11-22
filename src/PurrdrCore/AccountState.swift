/// 帳號與 Purrdr Plus 的狀態(#407、規格 #402):純邏輯，畫面與 model 只問它「現在是什麼狀態、哪些功能鎖著為什麼、有哪些動作」。
///
/// 通知與主機同步(Plus 功能)可用的條件只有一個:**已登入且有 Plus**。本機的開關狀態只決定「開著沒」，
/// 不能讓功能變成可用或完成(舊步驟卡曾因此在新會員身上打勾)。

/// 後台判定的這個會員的 Plus 狀態。
public enum PlusStatus: Equatable, Sendable {
    /// 沒有任何訂閱(從沒訂閱過)。
    case none
    /// 生效中。
    case active(source: MemberSubscription.Store)
    /// 帳單寬限期:扣款失敗、商店還在重試，仍有權限。
    case billingGrace(source: MemberSubscription.Store)
    /// 到期、退款或撤銷。
    case expired(source: MemberSubscription.Store)
    /// 這個 Apple ID 的訂閱綁在另一個會員(`maskedEmail` 是部分遮蔽的 email)。
    case ownedByAnotherMember(maskedEmail: String?)
    /// 暫時連不上後台，不知道訂閱狀態(不會因此登出)。
    case unreachable

    public init(subscription: MemberSubscription?) {
        guard let subscription else {
            self = .none
            return
        }
        switch subscription.status {
        case .active: self = .active(source: subscription.store)
        case .inGracePeriod: self = .billingGrace(source: subscription.store)
        case .expired, .revoked: self = .expired(source: subscription.store)
        }
    }

    /// 這個狀態有 Plus 權限(不含「有沒有登入」)。
    public var entitlesPlus: Bool {
        switch self {
        case .active, .billingGrace: true
        case .none, .expired, .ownedByAnotherMember, .unreachable: false
        }
    }

    /// 訂閱的付款來源;沒有訂閱或不知道時是 `nil`。
    public var source: MemberSubscription.Store? {
        switch self {
        case .active(let source), .billingGrace(let source), .expired(let source): source
        case .none, .ownedByAnotherMember, .unreachable: nil
        }
    }
}

/// 需要 Purrdr Plus 的功能。
public enum AccountFeature: CaseIterable, Sendable {
    case notifications
    case hostSync
}

/// 功能鎖住的原因;畫面依它顯示說明與下一步。
public enum FeatureLockReason: Equatable, Sendable {
    /// 還在確認登入狀態。
    case checkingAccount
    case signInRequired
    case plusRequired
    /// 訂閱屬於其他會員:可轉移。
    case subscriptionOwnedByAnotherMember
    /// 訂閱已到期:提示續訂。
    case subscriptionEnded
    /// 暫時連不上後台,不知道有沒有 Plus。
    case temporarilyUnreachable
}

public enum FeatureAvailability: Equatable, Sendable {
    case available
    case locked(FeatureLockReason)

    public var isAvailable: Bool { self == .available }
}

/// 帳號頁與付費牆上可能出現的動作。
public enum AccountAction: Equatable, Sendable {
    case signIn
    case join
    case activatePlus
    case restorePurchases
    /// 系統的管理訂閱畫面(取消、變更方案、更新付款方式)。
    case manageSubscription
    case transferSubscription
    /// 暫時連不上後重試。
    case retry
}

public struct AccountState: Equatable, Sendable {
    public enum Authentication: Equatable, Sendable {
        /// 啟動時還沒確認。
        case unknown
        case signedOut
        case signedIn
    }

    public var authentication: Authentication
    /// 沒登入時沒有意義(一律當作沒有 Plus)。
    public var plus: PlusStatus

    public init(authentication: Authentication, plus: PlusStatus = .none) {
        self.authentication = authentication
        self.plus = plus
    }

    public var isSignedIn: Bool { authentication == .signedIn }

    /// 已登入且有 Plus。
    public var hasPlus: Bool { isSignedIn && plus.entitlesPlus }

    /// 沒登入時先選「登入」或「加入會員」。
    public var needsEntryChoice: Bool { authentication == .signedOut }

    /// 帳單寬限期:仍有 Plus,但要提示更新付款方式。
    public var needsPaymentMethodUpdate: Bool {
        guard isSignedIn else { return false }
        switch plus {
        case .billingGrace: return true
        default: return false
        }
    }

    /// 曾經訂閱、現在到期:提示續訂。
    public var needsRenewal: Bool {
        guard isSignedIn, case .expired = plus else { return false }
        return true
    }

    public func availability(of feature: AccountFeature) -> FeatureAvailability {
        switch authentication {
        case .unknown: return .locked(.checkingAccount)
        case .signedOut: return .locked(.signInRequired)
        case .signedIn: break
        }
        switch plus {
        case .active, .billingGrace: return .available
        case .none: return .locked(.plusRequired)
        case .expired: return .locked(.subscriptionEnded)
        case .ownedByAnotherMember: return .locked(.subscriptionOwnedByAnotherMember)
        case .unreachable: return .locked(.temporarilyUnreachable)
        }
    }

    /// 功能算「完成」:可用,而且本機開著。可用性優先:鎖住時本機殘留的開關不算。
    public func isDone(_ feature: AccountFeature, isOnLocally: Bool) -> Bool {
        availability(of: feature).isAvailable && isOnLocally
    }

    /// 帳號頁此刻能做的動作。iOS 只販售 App Store 訂閱:Google Play 訂閱的會員有 Plus 但沒有購買或管理動作。
    public var availableActions: [AccountAction] {
        switch authentication {
        case .unknown: return []
        case .signedOut: return [.signIn, .join]
        case .signedIn: break
        }
        switch plus {
        case .none, .expired: return [.activatePlus, .restorePurchases]
        case .active(source: .appStore), .billingGrace(source: .appStore): return [.manageSubscription]
        case .active(source: .googlePlay), .billingGrace(source: .googlePlay): return []
        case .ownedByAnotherMember: return [.transferSubscription]
        case .unreachable: return [.retry]
        }
    }
}
