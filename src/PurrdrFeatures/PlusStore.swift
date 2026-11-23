import Foundation
import PurrdrCore
import StoreKit

/// 付費牆上的一個方案(StoreKit 的自動續訂商品)。
public struct PlusPlan: Equatable, Sendable, Identifiable {
    public var id: String
    /// 方案名稱(App Store Connect 的顯示名稱)。
    public var displayName: String
    /// 每期提供的內容。
    public var description: String
    /// 每期的總扣款金額，已依使用者的商店地區與幣別格式化。
    public var displayPrice: String
    /// 每期多長。
    public var period: PlusPeriod
    /// 免費試用的長度;這個 Apple 帳號沒有資格(已經用過)或商品沒有試用時是 `nil`。
    public var freeTrial: PlusPeriod?

    public init(id: String, displayName: String, description: String, displayPrice: String, period: PlusPeriod, freeTrial: PlusPeriod?) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.period = period
        self.freeTrial = freeTrial
    }
}

/// 訂閱期間。
public struct PlusPeriod: Equatable, Sendable {
    public enum Unit: Sendable {
        case day, week, month, year
    }

    public var value: Int
    public var unit: Unit

    public init(value: Int, unit: Unit) {
        self.value = value
        self.unit = unit
    }
}

/// StoreKit 交給 app 的一筆交易;`signedTransaction` 是 App Store 簽的 JWS,交給後台驗證。
public struct PlusTransaction: Equatable, Sendable {
    public var id: UInt64
    public var signedTransaction: String

    public init(id: UInt64, signedTransaction: String) {
        self.id = id
        self.signedTransaction = signedTransaction
    }
}

public enum PlusPurchaseOutcome: Equatable, Sendable {
    case purchased(PlusTransaction)
    /// 等待核准(Ask to Buy、需要額外驗證)。核准後經交易更新送來。
    case pending
    case canceled
}

/// StoreKit(Apple 平台服務，Seam 3)。正式實作是 `StoreKitPlusStore`;測試用記憶體內的假實作。
public protocol PlusStore: Sendable {
    /// 這台裝置能不能付款(螢幕使用時間等限制)。
    func paymentsAllowed() async -> Bool
    func loadPlans() async throws -> [PlusPlan]
    /// 用系統的購買確認畫面購買;`appAccountToken` 是會員 ID,後台據此把訂閱記到會員身上。
    func purchase(planID: String, appAccountToken: UUID) async throws -> PlusPurchaseOutcome
    /// 目前有效的 Purrdr Plus 交易(恢復購買、兌換後送給後台)。
    func currentTransactions() async -> [PlusTransaction]
    /// 恢復購買：跟 App Store 同步(可能要求登入 Apple 帳號)。
    func syncWithAppStore() async throws
    /// 交易已交給後台，通知 StoreKit 不必再送。
    func finish(_ transaction: PlusTransaction) async
    /// 在 app 外發生的交易：續訂、在別台裝置購買、兌換 Offer Code、Ask to Buy 核准。
    func transactionUpdates() async -> AsyncStream<PlusTransaction>
}

/// StoreKit 2 的實作。商品與購買在開發與 UI 測試時由 StoreKit 設定檔(`src/App/Purrdr.storekit`)提供。
@MainActor
public final class StoreKitPlusStore: PlusStore {
    /// 還沒 finish 的交易(finish 要用 StoreKit 的 `Transaction`)。
    private var unfinished: [UInt64: Transaction] = [:]
    private var products: [String: Product] = [:]

    public init() {}

    public func paymentsAllowed() async -> Bool {
        AppStore.canMakePayments
    }

    public func loadPlans() async throws -> [PlusPlan] {
        let loaded = try await Product.products(for: MemberSubscription.productIDs)
        var plans: [PlusPlan] = []
        // 依 productIDs 的順序(年繳在前)。
        for id in MemberSubscription.productIDs {
            guard let product = loaded.first(where: { $0.id == id }), let subscription = product.subscription else { continue }
            products[id] = product
            var trial: PlusPeriod?
            if let offer = subscription.introductoryOffer, offer.paymentMode == .freeTrial, await subscription.isEligibleForIntroOffer {
                trial = PlusPeriod(offer.period)
            }
            plans.append(PlusPlan(
                id: id, displayName: product.displayName, description: product.description,
                displayPrice: product.displayPrice, period: PlusPeriod(subscription.subscriptionPeriod), freeTrial: trial
            ))
        }
        return plans
    }

    public func purchase(planID: String, appAccountToken: UUID) async throws -> PlusPurchaseOutcome {
        guard let product = products[planID] else { throw StoreKitError.unknown }
        switch try await product.purchase(options: [.appAccountToken(appAccountToken)]) {
        case .success(let verification):
            return .purchased(keep(verification))
        case .pending:
            return .pending
        case .userCancelled:
            return .canceled
        @unknown default:
            return .canceled
        }
    }

    public func currentTransactions() async -> [PlusTransaction] {
        var result: [PlusTransaction] = []
        for await verification in Transaction.currentEntitlements where isPlus(verification) {
            result.append(keep(verification))
        }
        return result
    }

    public func syncWithAppStore() async throws {
        try await AppStore.sync()
    }

    public func finish(_ transaction: PlusTransaction) async {
        await unfinished.removeValue(forKey: transaction.id)?.finish()
    }

    public func transactionUpdates() async -> AsyncStream<PlusTransaction> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await verification in Transaction.updates {
                    guard let self, self.isPlus(verification) else { continue }
                    continuation.yield(self.keep(verification))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 不在 app 端判斷簽章是否可信：JWS 原封不動交給後台，由後台以 Apple 根憑證驗證。
    private func keep(_ verification: VerificationResult<Transaction>) -> PlusTransaction {
        let transaction = verification.unsafePayloadValue
        unfinished[transaction.id] = transaction
        return PlusTransaction(id: transaction.id, signedTransaction: verification.jwsRepresentation)
    }

    private func isPlus(_ verification: VerificationResult<Transaction>) -> Bool {
        MemberSubscription.productIDs.contains(verification.unsafePayloadValue.productID)
    }
}

extension PlusPeriod {
    init(_ period: Product.SubscriptionPeriod) {
        let unit: Unit = switch period.unit {
        case .day: .day
        case .week: .week
        case .month: .month
        case .year: .year
        @unknown default: .month
        }
        self.init(value: period.value, unit: unit)
    }
}
