/// 「設定 Purrdr Plus」步驟卡的進度(#246):加入會員 → 開通 Purrdr Plus → 開啟通知 → 同步主機名單。
///
/// 每一步依實際狀態算完成;不能跳著做，只有第一個沒完成的步驟是目前步驟。
public struct PlusSetupProgress: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        case joinMember
        case activatePlus
        case turnOnNotifications
        case syncHosts
    }

    public enum StepState: Equatable, Sendable {
        case done
        /// 下一個要做的步驟;只有它有按鈕。
        case current
        case upcoming
    }

    /// 通知與主機同步還不能開啟時，要先做的事。
    public enum LockedFeatureHint: Equatable, Sendable {
        case joinMemberFirst
        case activatePlusFirst
    }

    public let isMember: Bool
    public let isPlusActive: Bool
    public let isNotificationsOn: Bool
    public let isHostSyncOn: Bool

    public init(isMember: Bool, isPlusActive: Bool, isNotificationsOn: Bool, isHostSyncOn: Bool) {
        self.isMember = isMember
        self.isPlusActive = isPlusActive
        self.isNotificationsOn = isNotificationsOn
        self.isHostSyncOn = isHostSyncOn
    }

    public var currentStep: Step? {
        Step.allCases.first { !isDone($0) }
    }

    public func state(of step: Step) -> StepState {
        if isDone(step) { return .done }
        return step == currentStep ? .current : .upcoming
    }

    public var completedCount: Int {
        Step.allCases.filter(isDone).count
    }

    public var isComplete: Bool { currentStep == nil }

    public var lockedFeatureHint: LockedFeatureHint? {
        if isPlusActive { return nil }
        return isMember ? .activatePlusFirst : .joinMemberFirst
    }

    /// 剛開通 Purrdr Plus(`previous` 還沒開通),而且通知或同步還沒開：詢問是否立即開啟。
    public func offersFeatureSetup(after previous: PlusSetupProgress) -> Bool {
        isPlusActive && !previous.isPlusActive && !(isNotificationsOn && isHostSyncOn)
    }

    private func isDone(_ step: Step) -> Bool {
        switch step {
        case .joinMember: isMember
        case .activatePlus: isPlusActive
        // 沒登入時,本機殘留的通知與同步狀態不算完成(#328)。
        case .turnOnNotifications: isMember && isNotificationsOn
        case .syncHosts: isMember && isHostSyncOn
        }
    }
}
