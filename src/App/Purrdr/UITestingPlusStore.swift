import Foundation
import PurrdrFeatures

/// `-uiTesting` 用的 StoreKit 替身：內容與 StoreKit 設定檔 `src/App/Purrdr.storekit` 相同(en_US、美元)。
///
/// UI 測試保證不連網路;命令列的 `xcodebuild test` 又不會套用 scheme 的 StoreKit 設定檔
/// (實測：商品讀不到),真的 StoreKit 會去連 Sandbox。所以 UI 測試的付費牆用這個替身;
/// 真的 StoreKit 由開發時在 Xcode 執行(scheme 已指定設定檔)驗證。購買一律回「取消」。
@MainActor
final class UITestingPlusStore: PlusStore {
    private static let description = "Notifications when an agent needs you, and host sync across your devices."

    func paymentsAllowed() async -> Bool {
        true
    }

    func loadPlans() async throws -> [PlusPlan] {
        [
            PlusPlan(
                id: "com.raychiu.purrdr.plus.yearly", displayName: "Purrdr Plus Yearly", description: Self.description,
                displayPrice: "$39.99", period: PlusPeriod(value: 1, unit: .year), freeTrial: PlusPeriod(value: 2, unit: .week)
            ),
            PlusPlan(
                id: "com.raychiu.purrdr.plus.monthly", displayName: "Purrdr Plus Monthly", description: Self.description,
                displayPrice: "$4.99", period: PlusPeriod(value: 1, unit: .month), freeTrial: PlusPeriod(value: 2, unit: .week)
            ),
        ]
    }

    func purchase(planID: String, appAccountToken: UUID) async throws -> PlusPurchaseOutcome {
        .canceled
    }

    /// 這個 Apple 帳號目前有有效訂閱(`-uiTestingOwnedByOtherMemberPlus`:訂閱屬於另一個會員,恢復購買或轉移要送簽章交易)。
    private let hasCurrentTransaction: Bool

    init(hasCurrentTransaction: Bool = false) {
        self.hasCurrentTransaction = hasCurrentTransaction
    }

    func currentTransactions() async -> [PlusTransaction] {
        hasCurrentTransaction ? [PlusTransaction(id: 1, signedTransaction: "ui-testing-jws")] : []
    }

    func syncWithAppStore() async throws {}

    func finish(_ transaction: PlusTransaction) async {}

    func transactionUpdates() async -> AsyncStream<PlusTransaction> {
        AsyncStream { _ in }
    }
}
