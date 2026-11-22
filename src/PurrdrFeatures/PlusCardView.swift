import PurrdrCore
import SwiftUI

/// 帳號頁的 Purrdr Plus 卡(#409、設計稿第 27 組):狀態標題與說明、主要按鈕(開通、轉移、續訂、更新付款)、
/// 淡色的「管理訂閱」(只有 App Store 訂閱)、純文字的「恢復購買」。
///
/// 內容由核心的 `PlusCard` 決定;這裡只負責文字與排版。Google Play 訂閱在 iOS 只顯示來源,沒有任何購買或外部連結。
struct PlusCardView: View {
    let card: PlusCard
    let subscription: MemberSubscription?
    let isWorking: Bool
    let perform: (PlusCard.Button) -> Void
    let manage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if titleIsWarning {
                        // 圖示(非文字)用橘色;文字維持主要色,對比不受影響。
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.headline)
                }
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                if card.isStale {
                    Text("Showing your last known status.")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("account.plusCard.stale")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("account.plusCard.status")
            if let primary = card.primary {
                Button { perform(primary) } label: {
                    Text(label(primary)).frame(maxWidth: .infinity)
                }
                .filledProminentButtonStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(isWorking)
                .accessibilityIdentifier("account.plusCard.primary")
            }
            if card.manage != nil {
                Button(action: manage) {
                    Text("Manage Subscription").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("account.plusCard.manage")
            }
            if let secondary = card.secondary {
                Button { perform(secondary) } label: {
                    Text(label(secondary)).frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(isWorking)
                .accessibilityIdentifier("account.plusCard.secondary")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.plusCard")
    }

    private var titleIsWarning: Bool {
        switch card.kind {
        case .ownedByAnotherMember, .billingGrace: true
        default: false
        }
    }

    private func label(_ button: PlusCard.Button) -> LocalizedStringKey {
        switch button {
        case .activatePlus: "Activate Purrdr Plus"
        case .restorePurchases: "Restore Purchases"
        case .transferSubscription: "Move to This Member"
        case .updatePaymentMethod: "Update Payment Method"
        case .renew: "Renew Purrdr Plus"
        case .retry: "Try Again"
        }
    }

    private var title: LocalizedStringKey {
        switch card.kind {
        case .active: "Active"
        case .notActivated: "Not Activated"
        case .ownedByAnotherMember: "This Apple Account’s subscription belongs to another member"
        case .billingGrace: "Payment problem. Plus still works"
        case .expired: "Expired"
        case .unreachable: "Can’t check your subscription"
        }
    }

    private var detail: Text {
        switch card.kind {
        case .active(let source, let renewsAt):
            Text(Self.activeDetail(source: source, date: renewsAt, willRenew: subscription?.willAutoRenew != false))
        case .notActivated:
            Text("Activate to get notifications and sync your host list.")
        case .ownedByAnotherMember(let maskedEmail, let canTransfer):
            Text(Self.ownedDetail(maskedEmail: maskedEmail, canTransfer: canTransfer))
        case .billingGrace(_, let deadline):
            Text(deadline.map { String(localized: "The App Store couldn’t renew. Update your payment method by \($0.formatted(date: .long, time: .omitted)), or Plus will stop.") }
                ?? String(localized: "The App Store couldn’t renew. Update your payment method, or Plus will stop."))
        case .expired(_, let endedAt):
            Text(endedAt.map { String(localized: "Ended on \($0.formatted(date: .long, time: .omitted)). Notifications and host sync have stopped. Your data is still there.") }
                ?? String(localized: "Notifications and host sync have stopped. Your data is still there."))
        case .unreachable:
            Text("Purrdr couldn’t be reached. You’re still signed in.")
        }
    }

    static func activeDetail(source: MemberSubscription.Store, date: Date?, willRenew: Bool) -> String {
        switch source {
        case .appStore:
            guard let date else { return String(localized: "Subscribed through the App Store") }
            let text = date.formatted(date: .long, time: .omitted)
            return willRenew
                ? String(localized: "Subscribed through the App Store · Renews on \(text)")
                : String(localized: "Subscribed through the App Store · Ends on \(text). It won’t renew.")
        case .googlePlay:
            return String(localized: "Subscribed through Google Play. Manage it in Google Play. To switch to the App Store, cancel in Google Play first and wait for the current period to end.")
        }
    }

    static func ownedDetail(maskedEmail: String?, canTransfer: Bool) -> String {
        guard canTransfer else {
            return String(localized: "This member already has a subscription, and a member can have only one. To move this one, cancel the other first and wait for its period to end.")
        }
        if let maskedEmail {
            return String(localized: "It’s under \(maskedEmail). After you move it, the payment method and renewal date stay the same and future renewals go to this member. The original member loses Plus, and its notifications and host sync stop.")
        }
        return String(localized: "After you move it, the payment method and renewal date stay the same and future renewals go to this member. The original member loses Plus, and its notifications and host sync stop.")
    }
}

/// 沒有 Plus 時鎖定的功能列(通知、主機同步):列仍可點,說明鎖定原因與下一步;文字用 `secondaryText`(對比 ≥ 4.5:1),不用降低不透明度。
struct LockedFeatureRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let reason: FeatureLockReason
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 28)
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Label(reason.shortText, systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("Locked. \(reason.shortText)"))
        .accessibilityHint(Text("Explains what to do next."))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

extension FeatureLockReason {
    /// 鎖定列的一行說明。
    var shortText: String {
        switch self {
        case .checkingAccount: String(localized: "Checking your account")
        case .signInRequired: String(localized: "Sign in required")
        case .plusRequired: String(localized: "Needs Purrdr Plus")
        case .subscriptionOwnedByAnotherMember: String(localized: "Subscription belongs to another member")
        case .subscriptionEnded: String(localized: "Subscription ended")
        case .temporarilyUnreachable: String(localized: "Can’t check Plus right now")
        }
    }

    /// 點鎖定列後的完整說明與下一步。
    var explanation: String {
        switch self {
        case .checkingAccount: String(localized: "Purrdr is still checking your account. Try again in a moment.")
        case .signInRequired: String(localized: "Notifications and host sync belong to your Purrdr member account. Sign in first.")
        case .plusRequired: String(localized: "Notifications and host sync need Purrdr Plus. Activate it from the Purrdr Plus card above.")
        case .subscriptionOwnedByAnotherMember: String(localized: "This Apple Account’s subscription belongs to another member. Move it to this member from the Purrdr Plus card above.")
        case .subscriptionEnded: String(localized: "Your subscription has ended, so notifications and host sync are paused. Renew it from the Purrdr Plus card above.")
        case .temporarilyUnreachable: String(localized: "Purrdr can’t check your subscription right now. Try again when you’re online.")
        }
    }
}

extension View {
    /// 系統的管理訂閱畫面(取消、變更方案、更新付款方式);只有 iOS 有。
    @ViewBuilder
    func manageSubscriptions(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        manageSubscriptionsSheet(isPresented: isPresented)
        #else
        self
        #endif
    }
}
