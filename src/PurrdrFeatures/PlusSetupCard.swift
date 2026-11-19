import PurrdrCore
import SwiftUI

extension PlusSetupProgress {
    /// 由會員、訂閱、選取中主機的推播與主機同步的目前狀態組成(#246)。
    @MainActor
    init(member: MemberModel, plus: SubscriptionModel, push: PushModel?, hostSync: HostSyncModel?) {
        let isMember = if case .signedIn = member.phase { true } else { false }
        self.init(
            isMember: isMember,
            isPlusActive: isMember && plus.isPlusActive,
            isNotificationsOn: push?.state == .on,
            isHostSyncOn: hostSync?.isEnabled == true)
    }
}

/// 帳號頁的「設定 Purrdr Plus」步驟卡(#246):四步與進度條，只有目前那一步有按鈕。
struct PlusSetupCard: View {
    let progress: PlusSetupProgress
    /// 目前步驟正在進行(登入、購買、安裝外掛)時停用按鈕。
    let isWorking: Bool
    let perform: (PlusSetupProgress.Step) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set Up Purrdr Plus")
                .font(.headline)
            Text("\(progress.completedCount) of \(PlusSetupProgress.Step.allCases.count) Done")
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
            progressBar
                .padding(.vertical, 10)
            ForEach(PlusSetupProgress.Step.allCases, id: \.self) { step in
                Divider()
                row(step)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.plusSetup")
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(PlusSetupProgress.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(progress.state(of: step) == .done ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.secondary))
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    private func row(_ step: PlusSetupProgress.Step) -> some View {
        let state = progress.state(of: step)
        return HStack(spacing: 12) {
            StepBadge(number: step.rawValue + 1, state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .fontWeight(state == .current ? .semibold : .regular)
                Text(step.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityValue(state.accessibilityValue)
            .accessibilityIdentifier("account.plusSetup.\(step.identifier)")
            if state == .current {
                Button(step.actionTitle) { perform(step) }
                    .filledProminentButtonStyle()
                    .buttonBorderShape(.capsule)
                    .disabled(isWorking)
                    .accessibilityIdentifier("account.plusSetup.action")
            }
        }
        .padding(.vertical, 9)
    }
}

/// 步驟編號圓圈：完成是主色勾、目前是主色框、未到是灰底。
private struct StepBadge: View {
    let number: Int
    let state: PlusSetupProgress.StepState
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 26

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(.prominentFill)
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.onProminentFill)
            case .current:
                Circle().strokeBorder(.tint, lineWidth: 2)
                Text(verbatim: "\(number)")
                    .font(.footnote.bold())
                    .foregroundStyle(.tint)
            case .upcoming:
                Circle().fill(.fill.secondary)
                Text(verbatim: "\(number)")
                    .font(.footnote.bold())
                    .foregroundStyle(.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension PlusSetupProgress.Step {
    var title: LocalizedStringKey {
        switch self {
        case .joinMember: "Join as a Member"
        case .activatePlus: "Activate Purrdr Plus"
        case .turnOnNotifications: "Turn On Notifications"
        case .syncHosts: "Sync Host List"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .joinMember: "Sign in with Apple or Google"
        case .activatePlus: "Free trial available"
        case .turnOnNotifications: "Get notified when an agent needs you"
        case .syncHosts: "Share hosts between iPhone and iPad"
        }
    }

    var actionTitle: LocalizedStringKey {
        switch self {
        case .joinMember: "Join"
        case .activatePlus: "Activate"
        case .turnOnNotifications, .syncHosts: "Turn On"
        }
    }

    var identifier: String {
        switch self {
        case .joinMember: "join"
        case .activatePlus: "activate"
        case .turnOnNotifications: "notifications"
        case .syncHosts: "sync"
        }
    }
}

extension PlusSetupProgress.StepState {
    var accessibilityValue: Text {
        switch self {
        case .done: Text("Done")
        case .current: Text("Next Step")
        case .upcoming: Text("Not Yet")
        }
    }
}

extension PlusSetupProgress.LockedFeatureHint {
    var text: LocalizedStringKey {
        switch self {
        case .joinMemberFirst: "Notifications and host sync need Purrdr Plus. Join as a member first."
        case .activatePlusFirst: "Notifications and host sync need Purrdr Plus. Activate it next."
        }
    }
}
