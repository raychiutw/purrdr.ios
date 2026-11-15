import Foundation
import PurrdrFeatures

/// 記憶體內的 StoreKit(Seam 3):預先設定商品與購買結果，記下購買、finish 與同步。
@MainActor
final class FakePlusStore: PlusStore {
    static let monthly = PlusPlan(
        id: "com.raychiu.purrdr.plus.monthly", displayName: "Purrdr Plus Monthly",
        description: "Notifications when an agent needs you, and host sync across your devices.",
        displayPrice: "$4.99", period: PlusPeriod(value: 1, unit: .month), freeTrial: PlusPeriod(value: 2, unit: .week)
    )
    static let yearly = PlusPlan(
        id: "com.raychiu.purrdr.plus.yearly", displayName: "Purrdr Plus Yearly",
        description: "Notifications when an agent needs you, and host sync across your devices.",
        displayPrice: "$39.99", period: PlusPeriod(value: 1, unit: .year), freeTrial: PlusPeriod(value: 2, unit: .week)
    )

    var plans: [PlusPlan] = []
    var plansError = false
    var canMakePayments = true
    var purchaseOutcome: PlusPurchaseOutcome = .canceled
    var current: [PlusTransaction] = []
    private(set) var purchases: [(planID: String, appAccountToken: UUID)] = []
    private(set) var finished: [UInt64] = []
    private(set) var syncCount = 0
    private var updates: AsyncStream<PlusTransaction>.Continuation?
    private lazy var updateStream: AsyncStream<PlusTransaction> = AsyncStream { self.updates = $0 }

    func paymentsAllowed() async -> Bool {
        canMakePayments
    }

    func loadPlans() async throws -> [PlusPlan] {
        if plansError { throw URLError(.notConnectedToInternet) }
        return plans
    }

    func purchase(planID: String, appAccountToken: UUID) async throws -> PlusPurchaseOutcome {
        purchases.append((planID, appAccountToken))
        return purchaseOutcome
    }

    func currentTransactions() async -> [PlusTransaction] {
        current
    }

    func syncWithAppStore() async throws {
        syncCount += 1
    }

    func finish(_ transaction: PlusTransaction) async {
        finished.append(transaction.id)
    }

    func transactionUpdates() async -> AsyncStream<PlusTransaction> {
        updateStream
    }

    /// 模擬 StoreKit 的 `Transaction.updates`(續訂、在別處購買、兌換 Offer Code)。
    func deliverUpdate(_ transaction: PlusTransaction) {
        _ = updateStream
        updates?.yield(transaction)
    }
}
