import PurrdrCore
import Testing

/// 會員頁的「設定 Purrdr Plus」步驟卡(#246):加入會員 → 開通 Purrdr Plus → 開啟通知 → 同步主機名單。
@Suite("Purrdr Plus 開通步驟")
struct PlusSetupProgressTests {
    @Test("未加入會員：目前是加入會員，其餘步驟還沒到")
    func notMemberStartsAtJoin() {
        let progress = PlusSetupProgress(isMember: false, isPlusActive: false, isNotificationsOn: false, isHostSyncOn: false)

        #expect(progress.currentStep == .joinMember)
        #expect(progress.state(of: .joinMember) == .current)
        #expect(progress.state(of: .activatePlus) == .upcoming)
        #expect(progress.state(of: .turnOnNotifications) == .upcoming)
        #expect(progress.state(of: .syncHosts) == .upcoming)
        #expect(progress.completedCount == 0)
        #expect(!progress.isComplete)
    }

    @Test("已加入會員、未開通：目前是開通 Purrdr Plus")
    func memberWithoutPlusIsAtActivate() {
        let progress = PlusSetupProgress(isMember: true, isPlusActive: false, isNotificationsOn: false, isHostSyncOn: false)

        #expect(progress.currentStep == .activatePlus)
        #expect(progress.state(of: .joinMember) == .done)
        #expect(progress.state(of: .turnOnNotifications) == .upcoming)
        #expect(progress.completedCount == 1)
    }

    @Test("開通後：目前是開啟通知，同步主機名單還沒到")
    func plusActiveIsAtNotifications() {
        let progress = PlusSetupProgress(isMember: true, isPlusActive: true, isNotificationsOn: false, isHostSyncOn: false)

        #expect(progress.currentStep == .turnOnNotifications)
        #expect(progress.state(of: .syncHosts) == .upcoming)
        #expect(progress.completedCount == 2)
    }

    @Test("通知已開：目前是同步主機名單")
    func notificationsOnIsAtSync() {
        let progress = PlusSetupProgress(isMember: true, isPlusActive: true, isNotificationsOn: true, isHostSyncOn: false)

        #expect(progress.currentStep == .syncHosts)
        #expect(progress.completedCount == 3)
    }

    @Test("同步先開了、通知還沒：同步算完成，目前仍是開啟通知")
    func syncOnBeforeNotifications() {
        let progress = PlusSetupProgress(isMember: true, isPlusActive: true, isNotificationsOn: false, isHostSyncOn: true)

        #expect(progress.currentStep == .turnOnNotifications)
        #expect(progress.state(of: .syncHosts) == .done)
        #expect(progress.completedCount == 3)
    }

    @Test("四步都完成：沒有目前步驟，收成一列")
    func allDone() {
        let progress = PlusSetupProgress(isMember: true, isPlusActive: true, isNotificationsOn: true, isHostSyncOn: true)

        #expect(progress.currentStep == nil)
        #expect(progress.isComplete)
        #expect(progress.completedCount == 4)
        #expect(PlusSetupProgress.Step.allCases.allSatisfy { progress.state(of: $0) == .done })
    }

    @Test("未開通時通知與同步鎖住，並說明下一步")
    func lockedFeaturesExplainNextStep() {
        let notMember = PlusSetupProgress(isMember: false, isPlusActive: false, isNotificationsOn: false, isHostSyncOn: false)
        let member = PlusSetupProgress(isMember: true, isPlusActive: false, isNotificationsOn: false, isHostSyncOn: false)
        let plus = PlusSetupProgress(isMember: true, isPlusActive: true, isNotificationsOn: false, isHostSyncOn: false)

        #expect(notMember.lockedFeatureHint == .joinMemberFirst)
        #expect(member.lockedFeatureHint == .activatePlusFirst)
        #expect(plus.lockedFeatureHint == nil)
    }

    @Test("剛開通 Purrdr Plus 且通知或同步還沒開：詢問是否立即開啟")
    func offersFeatureSetupRightAfterActivation() {
        let before = PlusSetupProgress(isMember: true, isPlusActive: false, isNotificationsOn: false, isHostSyncOn: false)
        let after = PlusSetupProgress(isMember: true, isPlusActive: true, isNotificationsOn: false, isHostSyncOn: false)
        let alreadyOn = PlusSetupProgress(isMember: true, isPlusActive: true, isNotificationsOn: true, isHostSyncOn: true)

        #expect(after.offersFeatureSetup(after: before))
        #expect(!after.offersFeatureSetup(after: after), "原本就開通了不再問")
        #expect(!alreadyOn.offersFeatureSetup(after: before), "通知與同步都已開啟不問")
    }
}
