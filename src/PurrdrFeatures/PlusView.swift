import PurrdrCore
import StoreKit
import SwiftUI

/// Purrdr Plus 的付費牆與訂閱摘要(HIG 檢核清單 20.12、ASRG 3.1.2、Schedule 2 §3.8)。
///
/// - 每個方案揭露名稱、期間、每期內容、當地幣別的總扣款金額(最醒目的價格)與免費試用;
///   說明試用結束後自動扣款、續訂與取消方式;恢復購買、兌換代碼、使用條款與隱私權政策都在同一頁。
/// - 購買確認用系統 sheet;兌換代碼用系統的 Offer Code 流程;已訂閱時不推銷，改顯示摘要與「管理訂閱」(系統 UI)。
/// - 不能付款時隱藏購買並說明。付費牆一律可以關閉，聊天與終端機不需要訂閱。
/// - 權限記在會員身上：沒登入時主要按鈕先帶去登入。
public struct PlusView: View {
    let model: SubscriptionModel
    let member: MemberModel
    @State private var selectedPlanID: String?
    @State private var signingIn = false
    @State private var redeeming = false
    @State private var managing = false
    @Environment(\.openURL) private var openURL

    public init(model: SubscriptionModel, member: MemberModel) {
        self.model = model
        self.member = member
    }

    private var signedInMember: Member? {
        if case .signedIn(let member) = member.phase { return member }
        return nil
    }

    private var selectedPlan: PlusPlan? {
        model.plans.first { $0.id == selectedPlanID } ?? model.plans.first
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let subscription = model.subscription, subscription.isActive {
                    SubscriptionSummary(subscription: subscription, plans: model.plans) { managing = true }
                } else {
                    if model.needsRenewal {
                        RenewalPrompt()
                    }
                    storefront
                }
                otherActions
                legalLinks
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .disabled(model.isWorking)
        .navigationTitle("Purrdr Plus")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if member.phase == .unknown { await member.restore() }
            await model.loadPlans()
        }
        .task(id: signedInMember?.id) {
            await model.refresh()
        }
        .sheet(isPresented: $signingIn) {
            SignInSheet(model: member)
        }
        #if os(iOS)
        .offerCodeRedemption(isPresented: $redeeming) { _ in
            Task { await model.offerCodeRedemptionFinished() }
        }
        .manageSubscriptionsSheet(isPresented: $managing)
        #endif
        .alert(model.notice?.title ?? "", isPresented: noticePresented, presenting: model.notice) { notice in
            if notice == .signInRequired {
                Button("Sign In") { signingIn = true }
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    // MARK: - 區塊

    /// 每期提供的內容(App Store 3.1.2);頁首只有導覽列標題，不再重複標題與說明(#236)。
    private var header: some View {
        Text("Each subscription period includes notifications when an agent needs you, and your host list synced across your devices.")
            .accessibilityIdentifier("plus.benefits")
    }

    @ViewBuilder
    private var storefront: some View {
        switch model.storefront {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .paymentsDisabled:
            Label {
                Text("Purchases aren’t allowed on this device, for example because of Screen Time. You can still restore a subscription you already have.")
            } icon: {
                Image(systemName: "lock")
            }
            .accessibilityIdentifier("plus.paymentsDisabled")
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn’t load subscription options. Check your connection and try again.")
                Button("Try Again") { Task { await model.loadPlans() } }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        case .available:
            plans
        }
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.plans) { plan in
                PlanRow(plan: plan, isSelected: plan.id == selectedPlan?.id) { selectedPlanID = plan.id }
            }
            subscribeButton
            if let plan = selectedPlan {
                Text(plan.disclosure)
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("plus.disclosure")
            }
        }
    }

    private var subscribeButton: some View {
        Button {
            guard let plan = selectedPlan else { return }
            if let signedInMember {
                Task { await model.purchase(planID: plan.id, member: signedInMember) }
            } else {
                signingIn = true
            }
        } label: {
            Text(subscribeTitle)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .filledProminentButtonStyle()
        .accessibilityIdentifier("plus.subscribe")
    }

    private var subscribeTitle: LocalizedStringKey {
        if signedInMember == nil { return "Sign In to Subscribe" }
        return selectedPlan?.freeTrial == nil ? "Subscribe" : "Start Free Trial"
    }

    /// 恢復購買與兌換代碼：權限記在會員身上，所以也要先登入。
    private var otherActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { restoreButton; redeemButton }
            VStack(alignment: .leading, spacing: 12) { restoreButton; redeemButton }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            if signedInMember == nil { signingIn = true } else { Task { await model.restore() } }
        }
        .accessibilityIdentifier("plus.restore")
    }

    private var redeemButton: some View {
        Button("Redeem Code") {
            if signedInMember == nil { signingIn = true } else { redeeming = true }
        }
        .accessibilityIdentifier("plus.redeem")
    }

    private var legalLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { termsLink; privacyLink }
            VStack(alignment: .leading, spacing: 12) { termsLink; privacyLink }
        }
        .font(.footnote)
    }

    private var termsLink: some View {
        Link(destination: PurrdrLinks.termsOfUse) {
            Text("Terms of Use").frame(minHeight: 44)
        }
        .accessibilityIdentifier("plus.terms")
    }

    private var privacyLink: some View {
        Link(destination: PurrdrLinks.privacyPolicy) {
            Text("Privacy Policy").frame(minHeight: 44)
        }
        .accessibilityIdentifier("plus.privacy")
    }
}

/// 從頂層選單開啟的 Purrdr Plus sheet:付費牆加上「完成」(付費牆一律可以關閉)。
public struct PlusSheet: View {
    let model: SubscriptionModel
    let member: MemberModel
    @Environment(\.dismiss) private var dismiss

    public init(model: SubscriptionModel, member: MemberModel) {
        self.model = model
        self.member = member
    }

    public var body: some View {
        NavigationStack {
            PlusView(model: model, member: member)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("plus.done")
                    }
                }
        }
    }
}

/// Purrdr 的對外連結(付費牆、設定頁共用)。
///
/// 網頁原始碼在 `docs/site/purrdr/`,發佈到 `raychiutw.github.io/purrdr/`(#36)。
/// App Store Connect 的 Privacy Policy URL、Support URL 要填同樣的網址。
public enum PurrdrLinks {
    /// 使用 Apple 的標準 EULA(App Store Connect 沒有自訂 EULA 時適用)。
    public static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// 隱私權政策。
    public static let privacyPolicy = URL(string: "https://raychiutw.github.io/purrdr/privacy/")!
    /// App Store id:App Store Connect → App 資訊 → 一般資訊 → Apple ID(數字)。全 app 只在這裡填
    /// (設定頁與歡迎頁的「為 Purrdr 評分」都從這裡來);後台 `raychiutw/purrdr.server` 的 `wrangler.jsonc` 的 `APP_STORE_APP_APPLE_ID` 是同一個數字。
    public static let appStoreID = "6835416115"
    /// 支援頁(常見問題與聯絡方式)。
    public static let support = URL(string: "https://raychiutw.github.io/purrdr/support/")!
    /// 主機服務(HTTPS 連線方式)的安裝、配對、更新與解除安裝說明(#198)。
    public static let hostServiceGuide = URL(string: "https://raychiutw.github.io/purrdr/host-service/")!
}

// MARK: - 方案列

/// 一個方案：名稱、總扣款金額(最醒目)與期間、試用。整列是一個按鈕，選取時打勾。
struct PlanRow: View {
    let plan: PlusPlan
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondaryText))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.displayName)
                        .font(.headline)
                    Text(plan.pricePerPeriod)
                        .font(.title3.bold())
                    if let trial = plan.freeTrial {
                        Text("\(trial.phrase) free, then \(plan.pricePerPeriod)")
                            .font(.subheadline)
                            .foregroundStyle(.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.pressableCard(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(plan.accessibilityLabel))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("plus.plan.\(plan.id)")
    }
}

// MARK: - 已訂閱與續訂提示

/// 已訂閱：方案、續訂或結束日期、管理訂閱(系統 UI,取消也在這裡)。
struct SubscriptionSummary: View {
    let subscription: MemberSubscription
    let plans: [PlusPlan]
    let manage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You’re subscribed", systemImage: "checkmark.seal.fill")
                .font(.headline)
            if let plan = plans.first(where: { $0.id == subscription.productID }) {
                Text(plan.displayName)
            }
            Text(subscription.summary)
                .foregroundStyle(.secondaryText)
                .accessibilityIdentifier("plus.summary")
            if subscription.store == .appStore {
                Button("Manage Subscription", action: manage)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("plus.manage")
            } else {
                Text("This subscription is billed through Google Play. Manage it there.")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 訂閱到期或退款後：說明推播與主機同步已停止，聊天與終端機不受影響。
struct RenewalPrompt: View {
    var body: some View {
        Label {
            Text("Your Purrdr Plus subscription has ended. Notifications and host sync are paused until you subscribe again. Chat and terminal keep working.")
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .accessibilityIdentifier("plus.renewalPrompt")
    }
}

// MARK: - 文字

extension PlusPeriod {
    /// 「2 weeks」「month」:接在數字後或 per 後面用。
    var phrase: String {
        switch (unit, value) {
        case (.day, 1): String(localized: "1 day")
        case (.day, _): String(localized: "\(value) days")
        case (.week, 1): String(localized: "1 week")
        case (.week, _): String(localized: "\(value) weeks")
        case (.month, 1): String(localized: "1 month")
        case (.month, _): String(localized: "\(value) months")
        case (.year, 1): String(localized: "1 year")
        case (.year, _): String(localized: "\(value) years")
        }
    }

    /// 「month」「3 months」:接在「per」或「/」後面。
    var perPhrase: String {
        guard value == 1 else { return phrase }
        return switch unit {
        case .day: String(localized: "day")
        case .week: String(localized: "week")
        case .month: String(localized: "month")
        case .year: String(localized: "year")
        }
    }
}

extension PlusPlan {
    /// 「$4.99 per month」:每期的總扣款金額。
    var pricePerPeriod: String {
        String(localized: "\(displayPrice) per \(period.perPhrase)")
    }

    var accessibilityLabel: String {
        var parts = [displayName, pricePerPeriod]
        if let trial = freeTrial { parts.append(String(localized: "\(trial.phrase) free, then \(pricePerPeriod)")) }
        parts.append(description)
        return parts.joined(separator: ", ")
    }

    /// 自動續訂的揭露(Schedule 2 §3.8(b)、HIG:試用結束後自動扣款)。
    var disclosure: String {
        let renewal = String(localized: "\(displayName) renews automatically at \(pricePerPeriod) unless you cancel at least 24 hours before the end of the current period. Payment is charged to your Apple Account. Manage or cancel anytime in Settings › Apple Account › Subscriptions.")
        guard let trial = freeTrial else {
            return String(localized: "Payment of \(displayPrice) is charged when you confirm. ") + renewal
        }
        return String(localized: "Free for \(trial.phrase). When the trial ends, \(displayPrice) is charged automatically unless you cancel at least 24 hours before it ends. ") + renewal
    }
}

extension MemberSubscription {
    var summary: String {
        let date = expiresAt.formatted(date: .long, time: .omitted)
        switch status {
        case .inGracePeriod:
            let grace = (gracePeriodExpiresAt ?? expiresAt).formatted(date: .long, time: .omitted)
            return String(localized: "Apple couldn’t charge your payment method. Update it by \(grace) to keep Purrdr Plus.")
        case .active where willAutoRenew == false:
            return String(localized: "Ends on \(date). It won’t renew.")
        default:
            return String(localized: "Renews on \(date).")
        }
    }
}

extension SubscriptionModel {
    /// 會員頁上的一行狀態。
    var statusText: LocalizedStringKey {
        switch subscription?.status {
        case nil: "Not Subscribed"
        case .active: "Active"
        case .inGracePeriod: "Payment Issue"
        case .expired: "Expired"
        case .revoked: "Ended"
        }
    }
}

extension SubscriptionNotice {
    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Welcome to Purrdr Plus"
        case .restored: "Purchases Restored"
        case .nothingToRestore: "Nothing to Restore"
        case .pending: "Waiting for Approval"
        case .inUseByAnotherMember: "Used by Another Member"
        case .purchaseNotDelivered: "Almost Done"
        case .signInRequired: "Sign In to Continue"
        case .failed: "Couldn’t Finish"
        }
    }

    var message: String {
        switch self {
        case .welcome:
            String(localized: "Notifications when an agent needs you and host sync are now available. Turn them on for each host.")
        case .restored:
            String(localized: "Your Purrdr Plus subscription is active on this member account.")
        case .nothingToRestore:
            String(localized: "This Apple Account has no active Purrdr Plus subscription.")
        case .pending:
            String(localized: "The purchase is waiting for approval. Purrdr Plus turns on as soon as it’s approved.")
        case .inUseByAnotherMember:
            String(localized: "This Apple Account’s Purrdr Plus subscription belongs to another Purrdr member. Sign in with that member to use it.")
        case .purchaseNotDelivered:
            String(localized: "You’ve paid, but Purrdr couldn’t be reached to turn on Purrdr Plus. It will finish automatically next time you open Purrdr online.")
        case .signInRequired:
            String(localized: "Purrdr Plus belongs to your Purrdr member account. Sign in, and your purchase is added automatically.")
        case .failed:
            String(localized: "Something went wrong. Try again.")
        }
    }
}
