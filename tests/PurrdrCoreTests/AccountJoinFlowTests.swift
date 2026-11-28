import PurrdrCore
import Testing

/// 加入會員流程(#407、規格 #402):建立會員 → 開通 Plus(可略過) → 開啟通知 → 同步主機 → 完成。
@Suite("加入會員流程")
struct AccountJoinFlowTests {
    @Test("從建立會員開始，依序前進到完成")
    func advancesInOrder() {
        var flow = AccountJoinFlow()
        #expect(flow.step == .createMember)

        flow.advance()
        #expect(flow.step == .activatePlus)
        flow.advance()
        #expect(flow.step == .turnOnNotifications)
        flow.advance()
        #expect(flow.step == .syncHosts)
        flow.advance()
        #expect(flow.step == .finished)
        #expect(flow.completion == .plusReady)

        flow.advance()
        #expect(flow.step == .finished, "完成後停在完成頁")
    }

    @Test("第 1 步沒有左上動作可回；第 2 步起左上是關閉，不會回到已完成的建立會員")
    func leadingAction() {
        var flow = AccountJoinFlow()
        #expect(flow.leadingAction == .back)

        flow.advance()
        #expect(flow.leadingAction == .close)
        flow.advance()
        #expect(flow.leadingAction == .close)
    }

    @Test("略過 Plus：通知步驟照常可開(通知不需要 Plus,#675),跳過同步，完成頁是「會員已建立」")
    func skippingPlus() {
        var flow = AccountJoinFlow()
        flow.advance()
        flow.skipPlus()

        #expect(flow.step == .turnOnNotifications)
        #expect(flow.skippedPlus)
        #expect(!flow.visibleSteps.contains(.syncHosts))

        flow.advance()
        #expect(flow.step == .finished, "略過後通知步驟直接收尾，不進同步")
        #expect(flow.completion == .memberCreated)
    }

    @Test("有 Plus 的流程：通知步驟不鎖，四步都可見，完成頁是 Plus 已就緒")
    func withPlus() {
        var flow = AccountJoinFlow()
        flow.advance()
        flow.advance()

        #expect(!flow.skippedPlus)
        #expect(flow.visibleSteps == [.createMember, .activatePlus, .turnOnNotifications, .syncHosts])
    }

    @Test("略過後在通知步驟開通 Plus：回到有 Plus 的流程，通知解鎖並保留同步步驟")
    func activatingAfterSkip() {
        var flow = AccountJoinFlow()
        flow.advance()
        flow.skipPlus()
        flow.plusActivated()

        #expect(!flow.skippedPlus)
        #expect(flow.step == .turnOnNotifications)
        flow.advance()
        #expect(flow.step == .syncHosts)
    }

    @Test("只有在開通 Plus 那一步才能略過")
    func skipOnlyAtActivate() {
        var flow = AccountJoinFlow()
        flow.skipPlus()
        #expect(flow.step == .createMember)
        #expect(!flow.skippedPlus)
    }
}
