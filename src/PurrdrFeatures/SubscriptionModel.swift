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

    /// 付費牆預設選取的方案:排序後的第一個(年繳在前)。
    public var defaultPlan: PlusPlan? { plans.first }
    public private(set) var storefront: Storefront = .loading
    /// 後台判定的訂閱;沒登入或從沒訂閱過是 `nil`。
    public private(set) var subscription: MemberSubscription?
    /// 正在購買、恢復購買或送交易到後台;畫面據此停用按鈕。
    public private(set) var isWorking = false
    /// 要提示使用者的事。畫面顯示後設回 `nil`。
    public var notice: SubscriptionNotice?

    /// 這個 Apple 帳號的訂閱屬於另一個會員(購買或恢復時後台回 `subscription_in_use`,#409):帳號頁顯示轉移選項而非「未開通」。
    public struct TransferOffer: Equatable, Sendable {
        /// 擁有者的遮蔽 email(`r***@icloud.com`);後台沒有時是 `nil`。
        public var maskedEmail: String?
        /// 這個會員沒有佔著有效訂閱名額。
        public var canTransfer: Bool
    }

    public private(set) var transferOffer: TransferOffer?
    /// 顯示的是上次讀到的訂閱(這一次連不上後台);連得上就消失。
    public private(set) var isStale = false
    /// Plus 是依 StoreKit 的權限先行生效、後台還沒確認(#413)。後台回應(成功、拒絕或讀到狀態)後一律以後台為準。
    public private(set) var isPlusProvisional = false
    /// 最近一次讀取訂閱連不上後台。
    private var lastRefreshFailed = false

    private let session: MemberSession
    private let store: any PlusStore
    private let confirmOwner: (@MainActor @Sendable () async -> Bool)?

    /// - Parameter confirmOwner: 轉移訂閱前要求裝置擁有者驗證(Face ID／Touch ID／密碼);回 `false` 就不轉移。`nil` 時不驗證(只有測試)。
    public init(session: MemberSession, store: any PlusStore, confirmOwner: (@MainActor @Sendable () async -> Bool)? = nil) {
        self.session = session
        self.store = store
        self.confirmOwner = confirmOwner
    }

    /// 帳號頁用的 Plus 狀態:後台判定的訂閱優先;沒有 Plus 時,Apple 帳號的訂閱屬於別的會員會顯示轉移;連不上又沒讀到過是「連不上」。
    public var plusStatus: PlusStatus {
        let status = PlusStatus(subscription: subscription)
        if status.entitlesPlus { return status }
        if isPlusProvisional { return .active(source: .appStore) }
        if let transferOffer { return .ownedByAnotherMember(maskedEmail: transferOffer.maskedEmail) }
        if subscription == nil, lastRefreshFailed { return .unreachable }
        return status
    }

    public var plusCard: PlusCard {
        PlusCard(plus: plusStatus, subscription: subscription, canTransfer: transferOffer?.canTransfer ?? true, isStale: isStale)
    }

    /// 有 Purrdr Plus 權限(含帳單寬限期)。推播與主機同步據此開關。
    public var isPlusActive: Bool {
        subscription?.isActive == true || isPlusProvisional
    }

    /// 曾經訂閱、現在到期或被退款：提示續訂。
    public var needsRenewal: Bool {
        guard !isPlusProvisional else { return false }
        return subscription.map { !$0.isActive } ?? false
    }

    // MARK: - 付費牆

    public func loadPlans() async {
        guard await store.paymentsAllowed() else {
            storefront = .paymentsDisabled
            return
        }
        do {
            let loaded = try await store.loadPlans()
            // 依 productIDs 的順序(年繳在前);不認得的商品排在最後。
            let order = MemberSubscription.productIDs
            plans = loaded.sorted { (order.firstIndex(of: $0.id) ?? order.count) < (order.firstIndex(of: $1.id) ?? order.count) }
            storefront = plans.isEmpty ? .unavailable : .available
        } catch {
            storefront = .unavailable
        }
    }

    /// 讀取後台的訂閱狀態。沒登入時清成 `nil`,不提示。
    public func refresh() async {
        do {
            subscription = try await session.subscription()
            isPlusProvisional = false
            lastRefreshFailed = false
            isStale = false
            if subscription?.isActive == true { transferOffer = nil }
        } catch BackendError.signedOut {
            subscription = nil
            transferOffer = nil
            isPlusProvisional = false
            lastRefreshFailed = false
            isStale = false
        } catch {
            // 連不上時保留上次的狀態,標成上次資料(帳號頁不把它當成「未開通」)。
            lastRefreshFailed = true
            isStale = subscription != nil
        }
    }

    /// 把屬於另一個會員的 App Store 訂閱轉到目前會員:先要求裝置擁有者驗證,再把這個 Apple 帳號目前的簽章交易交給後台。
    /// 目前會員已有有效訂閱時後台會擋下(`.transferBlocked`);成功後 Plus 立即生效,原會員的通知與同步由後台停止。
    public func transferSubscription() async {
        guard transferOffer != nil, !isWorking else { return }
        if let confirmOwner, !(await confirmOwner()) {
            notice = .ownerNotConfirmed
            return
        }
        isWorking = true
        defer { isWorking = false }
        guard let transaction = await store.currentTransactions().first else {
            notice = .nothingToRestore
            return
        }
        do {
            subscription = try await session.transferAppStoreSubscription(transaction.signedTransaction)
            transferOffer = nil
            isStale = false
            lastRefreshFailed = false
            await store.finish(transaction)
            notice = .transferred
        } catch BackendError.signedOut {
            notice = .signInRequired
        } catch let BackendError.backend(_, code, _) where code == BackendErrorCode.subscriptionAlreadyActive {
            notice = .transferBlocked
        } catch let BackendError.backend(_, code, _) where code == BackendErrorCode.subscriptionAlreadyOwned {
            await refresh()
        } catch let BackendError.backend(_, code, _) where code == BackendErrorCode.subscriptionNotFound {
            // 這個訂閱沒登記在任何會員:不是轉移,走一般綁定。
            transferOffer = nil
            _ = await deliver(transaction, provisional: true)
        } catch {
            notice = .failed
        }
    }

    // MARK: - 購買

    /// 用系統的購買確認畫面購買;`member` 的 ID 當成 appAccountToken。
    public func purchase(planID: String, member: Member) async {
        // 一個會員同時只有一個有效訂閱:已經有就不再開購買畫面(避免付了款卻被後台擋下)。
        // 帳單重試期(#462)Apple 仍在扣款、後台仍佔名額:同樣不開購買畫面。
        if subscription?.occupiesSubscriptionSlot == true {
            notice = .alreadySubscribed
            return
        }
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
            if await deliver(transaction, provisional: true) == .delivered, isPlusActive {
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
        if subscription?.billingRetry == true {
            notice = .alreadySubscribed
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.syncWithAppStore()
        } catch {
            // 使用者取消 Apple 帳號登入等：仍用本機已知的交易繼續。
        }
        let transactions = await store.currentTransactions()
        for transaction in transactions {
            guard await deliver(transaction, provisional: true) == .delivered else { return }
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
    ///
    /// - Parameter provisional: 這筆是使用者剛購買或恢復的有效權限:後台還沒回應(連不上)時依 StoreKit 先讓 Plus 生效,
    ///   後台一回應(成功、拒絕)就以後台為準。沒登入時不先行生效(沒有會員就沒有 Plus)。
    private func deliver(_ transaction: PlusTransaction, provisional: Bool = false) async -> Delivery {
        do {
            subscription = try await session.submitAppStoreTransaction(transaction.signedTransaction)
            isPlusProvisional = false
            await store.finish(transaction)
            return .delivered
        } catch BackendError.signedOut {
            isPlusProvisional = false
            notice = .signInRequired
            return .retryLater
        } catch let BackendError.subscriptionInUse(ownerEmail, canTransfer) {
            isPlusProvisional = false
            transferOffer = TransferOffer(maskedEmail: ownerEmail, canTransfer: canTransfer)
            // 這個會員已有有效訂閱:不能轉移,說明原因(Plus 維持原本的訂閱)。
            notice = canTransfer ? .inUseByAnotherMember : .transferBlocked
            await store.finish(transaction)
            return .rejected
        } catch let BackendError.backend(_, code, _) where code == BackendErrorCode.subscriptionAlreadyActive {
            isPlusProvisional = false
            notice = .alreadySubscribed
            await store.finish(transaction)
            return .rejected
        } catch let BackendError.backend(status, _, _) where (400..<500).contains(status) && status != 401 {
            isPlusProvisional = false
            notice = .failed
            await store.finish(transaction)
            return .rejected
        } catch {
            if provisional, subscription?.isActive != true { isPlusProvisional = true }
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
    /// 轉移完成:Plus 歸這個會員。
    case transferred
    /// 這個會員已有另一個有效訂閱,不能轉移(一個會員同時只能有一個)。
    case transferBlocked
    /// 這個會員已有有效訂閱,不能再購買(一個會員同時只能有一個)。
    case alreadySubscribed
    /// 沒通過本人確認(取消或失敗):什麼都沒轉。
    case ownerNotConfirmed
    case failed
}
