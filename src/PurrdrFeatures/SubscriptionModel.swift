import Foundation
import Observation
import PurrdrCore

/// 訂閱 Purrdr Plus(付費牆、購買、恢復購買、兌換 Offer Code、訂閱狀態)的 model。
///
/// 權限記在會員身上(ADR-0007):StoreKit 的交易一律交給 Purrdr 後台驗證，`subscription` 是後台判定的結果。
/// 交易送到後台之後才 finish;送不到(沒登入、連不上)就留著，StoreKit 下次會再經交易更新送來。
///
/// 推播(#29)與主機同步(#30)看 `isPlusActive`;到期或退款後 `needsRenewal` 為真，畫面提示續訂。
@MainActor
@Observable
public final class SubscriptionModel {
    public enum Storefront: Equatable {
        case loading
        case available
        /// 這台裝置不能付款(螢幕使用時間等):不顯示購買。
        case paymentsDisabled
        /// 讀不到商品(沒網路等)。
        case unavailable
    }

    public private(set) var plans: [PlusPlan] = []
    public private(set) var storefront: Storefront = .loading
    /// 後台判定的訂閱;沒登入或從沒訂閱過是 `nil`。
    public private(set) var subscription: MemberSubscription?
    /// 正在購買、恢復購買或送交易到後台;畫面據此停用按鈕。
    public private(set) var isWorking = false
    /// 要提示使用者的事。畫面顯示後設回 `nil`。
    public var notice: SubscriptionNotice?

    private let session: MemberSession
    private let store: any PlusStore

    public init(session: MemberSession, store: any PlusStore) {
        self.session = session
        self.store = store
    }

    /// 有 Purrdr Plus 權限(含帳單寬限期)。推播與主機同步據此開關。
    public var isPlusActive: Bool {
        subscription?.isActive == true
    }

    /// 曾經訂閱、現在到期或被退款：提示續訂。
    public var needsRenewal: Bool {
        subscription.map { !$0.isActive } ?? false
    }

    // MARK: - 付費牆

    public func loadPlans() async {
        guard await store.paymentsAllowed() else {
            storefront = .paymentsDisabled
            return
        }
        do {
            plans = try await store.loadPlans()
            storefront = plans.isEmpty ? .unavailable : .available
        } catch {
            storefront = .unavailable
        }
    }

    /// 讀取後台的訂閱狀態。沒登入時清成 `nil`,不提示。
    public func refresh() async {
        do {
            subscription = try await session.subscription()
        } catch BackendError.signedOut {
            subscription = nil
        } catch {
            // 連不上時保留上次的狀態。
        }
    }

    // MARK: - 購買

    /// 用系統的購買確認畫面購買;`member` 的 ID 當成 appAccountToken。
    public func purchase(planID: String, member: Member) async {
        guard let token = UUID(uuidString: member.id) else {
            notice = .failed
            return
        }
        isWorking = true
        defer { isWorking = false }
        let outcome: PlusPurchaseOutcome
        do {
            outcome = try await store.purchase(planID: planID, appAccountToken: token)
        } catch {
            notice = .failed
            return
        }
        switch outcome {
        case .purchased(let transaction):
            if await deliver(transaction) == .delivered, isPlusActive {
                notice = .welcome
            }
        case .pending:
            notice = .pending
        case .canceled:
            break
        }
    }

    /// 恢復購買：跟 App Store 同步，把目前有效的交易送到後台;沒有就看後台是否已有訂閱(例如別的商店)。
    public func restore() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.syncWithAppStore()
        } catch {
            // 使用者取消 Apple 帳號登入等：仍用本機已知的交易繼續。
        }
        let transactions = await store.currentTransactions()
        for transaction in transactions {
            guard await deliver(transaction) == .delivered else { return }
        }
        if transactions.isEmpty { await refresh() }
        notice = isPlusActive ? .restored : .nothingToRestore
    }

    /// 兌換 Offer Code 的系統畫面結束後：把目前的交易送到後台(交易更新也會送來，重送無妨)。
    public func offerCodeRedemptionFinished() async {
        isWorking = true
        defer { isWorking = false }
        for transaction in await store.currentTransactions() {
            guard await deliver(transaction) == .delivered else { return }
        }
        if isPlusActive { notice = .welcome }
    }

    /// 處理 StoreKit 的交易更新，直到被取消。app 啟動時就要開始(未 finish 的交易會在這裡再送一次)。
    public func observeTransactionUpdates() async {
        for await transaction in await store.transactionUpdates() {
            await handle(transaction)
        }
    }

    /// 處理一筆在 app 外發生的交易(續訂、別台裝置購買、兌換 Offer Code、Ask to Buy 核准)。
    public func handle(_ transaction: PlusTransaction) async {
        _ = await deliver(transaction)
    }

    // MARK: -

    private enum Delivery {
        case delivered
        case rejected
        case retryLater
    }

    /// 交易送到後台。成功或後台明確拒絕(重送也不會變)才 finish。
    private func deliver(_ transaction: PlusTransaction) async -> Delivery {
        do {
            subscription = try await session.submitAppStoreTransaction(transaction.signedTransaction)
            await store.finish(transaction)
            return .delivered
        } catch BackendError.signedOut {
            notice = .signInRequired
            return .retryLater
        } catch let BackendError.backend(status, code, _) where (400..<500).contains(status) && status != 401 {
            notice = code == "subscription_in_use" ? .inUseByAnotherMember : .failed
            await store.finish(transaction)
            return .rejected
        } catch {
            notice = .purchaseNotDelivered
            return .retryLater
        }
    }
}

/// 訂閱畫面要提示的事。
public enum SubscriptionNotice: Equatable, Sendable {
    /// 訂閱生效(購買、兌換完成):歡迎並說明開通了什麼。
    case welcome
    case restored
    case nothingToRestore
    /// 等待核准(Ask to Buy)。
    case pending
    /// 這個 Apple 帳號的訂閱已屬於另一個 Purrdr 會員。
    case inUseByAnotherMember
    /// 已向 Apple 付款但還沒送到 Purrdr(連不上):之後會自動再試。
    case purchaseNotDelivered
    /// 要先登入會員。
    case signInRequired
    case failed
}
