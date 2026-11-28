import PurrdrCore
import Testing

/// 沒登入時的帳號頁(#408、規格 #402):先選「登入」或「加入會員」。登入直接進帳號頁;加入才走步驟流程。
@Suite("登入與加入分流")
struct AccountEntryFlowTests {
    @Test("一開始是選擇頁，左上是關閉")
    func startsAtChoice() {
        let flow = AccountEntryFlow()
        #expect(flow.screen == .choose)
        #expect(flow.leadingAction == .close)
        #expect(flow.title == .account)
        #expect(flow.stepIndicator == nil)
    }

    @Test("選登入進登入頁，左上是返回，返回回到選擇頁")
    func signInBranch() {
        var flow = AccountEntryFlow()
        flow.chooseSignIn()
        #expect(flow.screen == .signIn)
        #expect(flow.leadingAction == .back)
        #expect(flow.title == .signIn)
        #expect(flow.signInCopy == .signIn)

        flow.back()
        #expect(flow.screen == .choose)
    }

    @Test("選加入進建立會員(1 / 4)，按鈕用註冊的說法")
    func joinBranch() {
        var flow = AccountEntryFlow()
        flow.chooseJoin()
        #expect(flow.screen == .join)
        #expect(flow.join.step == .createMember)
        #expect(flow.leadingAction == .back)
        #expect(flow.title == .join)
        #expect(flow.stepIndicator == AccountStepIndicator(current: 1, total: 4))
        #expect(flow.signInCopy == .signUp)
    }

    @Test("登入頁與加入頁可以互相切換")
    func switchBetweenSignInAndJoin() {
        var flow = AccountEntryFlow()
        flow.chooseSignIn()
        flow.switchToJoin()
        #expect(flow.screen == .join)
        flow.switchToSignIn()
        #expect(flow.screen == .signIn)
        #expect(flow.join.step == .createMember, "切回登入不動加入流程")
    }

    @Test("登入後會員已存在：直接進帳號頁，不走步驟")
    func existingMemberSignsInToAccount() {
        var flow = AccountEntryFlow()
        flow.chooseSignIn()
        flow.signedIn(memberCreated: false)
        #expect(flow.screen == .account)
        #expect(flow.join.step == .createMember)
    }

    @Test("登入時後台其實新建了會員：接著走加入流程的第 2 步")
    func signInThatCreatedMemberContinuesJoin() {
        var flow = AccountEntryFlow()
        flow.chooseSignIn()
        flow.signedIn(memberCreated: true)
        #expect(flow.screen == .join)
        #expect(flow.join.step == .activatePlus)
        #expect(flow.leadingAction == .close, "第 2 步起左上是關閉")
    }

    @Test("加入後新建會員：前進到開通 Plus(2 / 4)，左上關閉")
    func joinCreatesMemberAdvancesToPlus() {
        var flow = AccountEntryFlow()
        flow.chooseJoin()
        flow.signedIn(memberCreated: true)
        #expect(flow.screen == .join)
        #expect(flow.join.step == .activatePlus)
        #expect(flow.leadingAction == .close)
        #expect(flow.stepIndicator == AccountStepIndicator(current: 2, total: 4))
    }

    @Test("加入時那個 email 已經是會員：直接登入那個會員，進帳號頁")
    func joinThatMatchesExistingMemberSignsIn() {
        var flow = AccountEntryFlow()
        flow.chooseJoin()
        flow.signedIn(memberCreated: false)
        #expect(flow.screen == .account)
        #expect(flow.joinedExistingMember)
    }

    @Test("略過 Plus：通知不鎖(#675)、仍標 3 / 4，完成頁是「會員已建立」")
    func skipPlusBranch() {
        var flow = AccountEntryFlow()
        flow.chooseJoin()
        flow.signedIn(memberCreated: true)
        flow.skipPlus()
        #expect(flow.join.step == .turnOnNotifications)
        #expect(flow.stepIndicator == AccountStepIndicator(current: 3, total: 4), "略過 Plus 仍標 3 / 4(設計稿)")

        flow.advance()
        #expect(flow.join.step == .finished, "略過 Plus 跳過同步")
        #expect(flow.join.completion == .memberCreated)
    }

    @Test("走完加入流程：完成頁後離開流程回到帳號頁")
    func finishLeavesFlow() {
        var flow = AccountEntryFlow()
        flow.chooseJoin()
        flow.signedIn(memberCreated: true)
        flow.advance()
        flow.advance()
        flow.advance()
        #expect(flow.join.step == .finished)
        #expect(flow.join.completion == .plusReady)
        #expect(flow.stepIndicator == nil, "完成頁不標步驟")
        flow.finish()
        #expect(flow.screen == .account)
    }

    @Test("略過後在通知步驟開通 Plus：解鎖通知，同步步驟回來")
    func activatingPlusAfterSkip() {
        var flow = AccountEntryFlow()
        flow.chooseJoin()
        flow.signedIn(memberCreated: true)
        flow.skipPlus()
        flow.plusActivated()
        flow.advance()
        #expect(flow.join.step == .syncHosts)
    }

    @Test("登出後從頭開始")
    func resetReturnsToChoice() {
        var flow = AccountEntryFlow()
        flow.chooseJoin()
        flow.signedIn(memberCreated: true)
        flow.reset()
        #expect(flow.screen == .choose)
        #expect(flow.join.step == .createMember)
    }

    @Test("不在對應畫面時的動作不生效")
    func ignoresActionsOutsideTheirScreen() {
        var flow = AccountEntryFlow()
        flow.switchToJoin()
        #expect(flow.screen == .choose)
        flow.skipPlus()
        #expect(flow.join.step == .createMember)
        flow.signedIn(memberCreated: true)
        #expect(flow.screen == .choose, "沒有在登入或加入頁，不接收登入結果")
    }
}

/// 帳號與設定改滿版 modal、下一頁一律 push(#623):沒登入流程的頁面堆疊由流程狀態推導,
/// 系統返回(堆疊變短)再回寫成流程狀態。
@Suite("登入與加入的頁面堆疊")
struct AccountEntryPathTests {
    @Test("選擇頁是根,沒有推入的頁")
    func chooseHasNoPushedPages() {
        #expect(AccountEntryFlow().path.isEmpty)
    }

    @Test("登入頁與加入的第 1 步各推入一頁")
    func signInAndJoinPushOnePage() {
        var flow = AccountEntryFlow()
        flow.chooseSignIn()
        #expect(flow.path == [.signIn])
        flow.switchToJoin()
        #expect(flow.path == [.join])
    }

    @Test("加入第 2 步起每一步再推入一頁,略過 Plus 後直接是通知步驟")
    func joinStepsAccumulate() {
        var flow = AccountEntryFlow()
        flow.chooseJoin()
        flow.signedIn(memberCreated: true)
        #expect(flow.path == [.join, .joinStep(.activatePlus)])
        flow.skipPlus()
        #expect(flow.path == [.join, .joinStep(.activatePlus), .joinStep(.turnOnNotifications)])
        flow.advance()
        #expect(flow.path.last == .joinStep(.finished))
    }

    @Test("離開流程(進帳號頁)後堆疊清空")
    func accountClearsPath() {
        var flow = AccountEntryFlow()
        flow.chooseSignIn()
        flow.signedIn(memberCreated: false)
        #expect(flow.path.isEmpty)
    }

    @Test("系統返回把堆疊清空:登入頁與加入第 1 步回到選擇頁")
    func poppingToRootGoesBack() {
        var flow = AccountEntryFlow()
        flow.chooseSignIn()
        flow.apply(path: [])
        #expect(flow.screen == .choose)

        flow.chooseJoin()
        flow.apply(path: [])
        #expect(flow.screen == .choose)
    }

    @Test("選擇頁點列推入登入頁或加入頁,流程跟著走")
    func pushingFromChooseSelectsPage() {
        var flow = AccountEntryFlow()
        flow.apply(path: [.signIn])
        #expect(flow.screen == .signIn)

        var other = AccountEntryFlow()
        other.apply(path: [.join])
        #expect(other.screen == .join)
        #expect(other.join.step == .createMember)
    }

    @Test("第 2 步起不能用返回回到已建立的會員:堆疊變短不改流程")
    func poppingJoinStepsIsIgnored() {
        var flow = AccountEntryFlow()
        flow.chooseJoin()
        flow.signedIn(memberCreated: true)
        flow.apply(path: [.join])
        #expect(flow.join.step == .activatePlus)
        #expect(flow.path == [.join, .joinStep(.activatePlus)])
    }
}
