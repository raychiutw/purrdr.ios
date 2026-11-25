import PurrdrCore
import SwiftUI

extension EnvironmentValues {
    /// UI 測試用(#408):Apple／Google 按鈕不開系統登入,直接用固定憑證登入假後台
    /// (註冊頁送 `ui-testing-new`、登入頁送 `ui-testing-existing`)。由 composition root 依 `-uiTesting` 注入。
    @Entry public var usesTestingSignIn = false
}

// MARK: - 選擇、登入、註冊(加入的第 1 步)

/// 沒登入時帳號頁的導覽(#408、#623):根是選擇頁,登入、加入與加入的各步驟都往右推入(`NavigationStack` 的 destination),
/// 左上是系統返回「<」。帳號 sheet 與付費牆的「登入以訂閱」共用。
///
/// 頁面堆疊由 `AccountEntryFlow` 推導(`path`):流程往前走(登入結果、略過、前進)就推入,
/// 系統返回(點「<」或左緣滑回)再經 `apply(path:)` 回寫成流程狀態,所以流程狀態永遠是唯一的來源。
struct AccountEntryStack<Root: View>: View {
    let model: MemberModel
    @Binding var entry: AccountEntryFlow
    let plus: SubscriptionModel?
    let pushes: [HostPush]
    let hostSync: HostSyncModel?
    let hostCount: Int
    /// 關閉整個 modal(第 2 步起左上的 X)。
    let onClose: () -> Void
    @ViewBuilder let root: Root

    @State private var pages: [AccountEntryFlow.Page] = []

    var body: some View {
        NavigationStack(path: $pages) {
            root
                .navigationDestination(for: AccountEntryFlow.Page.self) { page in
                    destination(page)
                }
        }
        // 對話框掛在最外層(NavigationStack 之外):掛在根頁上,推入登入頁後根頁不在畫面上,對話框不會出現。
        // 登入頁查無這個帳號的會員:擋下並問要不要加入,確認才進加入流程(#434)。
        .alert("No Member Found", isPresented: Binding(get: { model.memberNotFound }, set: { if !$0 { model.dismissMemberNotFound() } })) {
            Button("Join") { entry.switchToJoin() }
                .accessibilityIdentifier("member.notFound.join")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We couldn’t find a member for this account. Do you want to join?")
        }
        .alert(model.notice?.title ?? "", isPresented: noticePresented, presenting: model.notice) { notice in
            if notice == .deleted {
                Link("Manage Subscriptions", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
            }
            if notice == .signOutBackendUnreachable {
                Button("Sign Out Anyway", role: .destructive) { Task { await model.signOut(force: true) } }
                    .accessibilityIdentifier("member.signOutAnyway")
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { notice in
            Text(notice.message)
        }
        // 流程 → 堆疊:登入結果、前進、略過。
        .onChange(of: shownPath) { _, path in
            if pages != path { pages = path }
        }
        // 堆疊 → 流程:選擇頁點列推入、系統返回。
        .onChange(of: pages) { _, new in
            guard new != shownPath else { return }
            entry.apply(path: new)
            if pages != shownPath { pages = shownPath }
        }
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    private var shownPath: [AccountEntryFlow.Page] {
        entry.shownScreen(phase: model.phase, hasPlus: plus != nil) == nil ? [] : entry.path
    }

    @ViewBuilder
    private func destination(_ page: AccountEntryFlow.Page) -> some View {
        switch page {
        case .signIn:
            AccountAuthPage(model: model, entry: $entry, copy: .signIn)
                .entryPageChrome(title: "Sign In", entry: entry, page: page, onClose: onClose)
        case .join:
            AccountAuthPage(model: model, entry: $entry, copy: .signUp)
                .entryPageChrome(title: "Join as a Member", entry: entry, page: page, onClose: onClose)
        case .joinStep(let step):
            if let plus {
                JoinFlowPages(
                    model: model, entry: $entry, step: step, plus: plus, pushes: pushes, hostSync: hostSync,
                    hostCount: hostCount, signedInMember: signedInMember)
                    .entryPageChrome(title: "Join as a Member", entry: entry, page: page, onClose: onClose)
                    // 會員已建立,不回到上一步;要離開用左上的關閉。
                    .navigationBarBackButtonHidden()
            }
        }
    }

    private var signedInMember: Member? {
        if case .signedIn(let member) = model.phase { return member }
        return nil
    }
}

private extension View {
    func entryPageChrome(title: LocalizedStringKey, entry: AccountEntryFlow, page: AccountEntryFlow.Page, onClose: @escaping () -> Void) -> some View {
        navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { AccountEntryPageToolbar(entry: entry, page: page, onClose: onClose) }
    }
}

/// 選擇頁:Purrdr 圖示、說明與「登入」「加入會員」兩列。
struct ChoosePage: View {
    let settings: AccountSettings?

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.onProminentFill)
                        .frame(width: 84, height: 84)
                        .background(.prominentFill, in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityHidden(true)
                    Text("Purrdr Member")
                        .font(.title2.bold())
                    Text("A member account unlocks Purrdr Plus, notifications from your agents, and a host list that syncs across iPhone, iPad, and Android.")
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .accessibilityElement(children: .combine)
                .listRowBackground(Color.clear)
            }
            Section {
                ChoiceRow(title: "Sign In", detail: "Already a member", identifier: "account.entry.signIn", page: .signIn)
                ChoiceRow(title: "Join as a Member", detail: "First time here. We’ll set up Plus with you.", identifier: "account.entry.join", page: .join)
            } footer: {
                Text("Chat, terminal, and host management don’t need a member account.")
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondaryText)
            }
            if let settings { SettingsSections(settings) }
        }
        .appGroupedList()
        .accessibilityIdentifier("account.signedOut")
    }
}

/// 往右推入下一頁的列:列尾的 `>` 由系統的 `NavigationLink` 給(#623)。
private struct ChoiceRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let identifier: String
    let page: AccountEntryFlow.Page

    var body: some View {
        NavigationLink(value: page) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// 登入頁與建立會員頁:標題、說明,下方固定兩個登入鈕(不需捲動就看得到),最底是切換連結。
private struct AccountAuthPage: View {
    let model: MemberModel
    @Binding var entry: AccountEntryFlow
    let copy: AccountEntryFlow.SignInCopy

    private var isSignUp: Bool { copy == .signUp }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(isSignUp ? "Create Your Member Account" : "Sign In to Purrdr")
                    .font(.title2.bold())
                Text(isSignUp
                    ? "Pick one way to create it. You can link the other one later in Account."
                    : "Sign in with the method you used when you joined.")
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 16)
        }
        // 識別碼掛在 ScrollView 本身:掛在 safeAreaBar 外層會蓋掉登入鈕自己的識別碼。
        .accessibilityIdentifier(isSignUp ? "account.entry.joinPage" : "account.entry.signInPage")
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 8) {
                SignInButtons(model: model, linking: false, methods: SignInMethod.allCases, copy: copy)
                Text(isSignUp
                    ? "If this email already belongs to a member, you’ll be signed in to that member."
                    : "After you sign in, you go straight to Account.")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
                Button(isSignUp ? "Already a member? Sign In" : "Not a member yet? Join") {
                    if isSignUp { entry.switchToSignIn() } else { entry.switchToJoin() }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("account.entry.switch")
            }
            .padding()
        }
    }
}

// MARK: - 加入流程(第 2 步起)

/// 加入會員第 2~4 步與完成頁(#408,設計稿第 26 組)。第 2 步起左上是「關閉」(會員已建立,之後在帳號頁繼續)。
struct JoinFlowPages: View {
    let model: MemberModel
    @Binding var entry: AccountEntryFlow
    /// 這一頁是哪一步(每一步各自推入一頁,不看流程目前走到哪)。
    let step: AccountJoinFlow.Step
    let plus: SubscriptionModel
    let pushes: [HostPush]
    let hostSync: HostSyncModel?
    let hostCount: Int
    let signedInMember: Member?

    @State private var selectedPlanID: String?
    @State private var showingPlus = false

    var body: some View {
        Group {
            switch step {
            case .createMember, .activatePlus: paywallPage
            case .turnOnNotifications: notificationsPage
            case .syncHosts: syncPage
            case .finished: donePage
            }
        }
        .navigationDestination(isPresented: $showingPlus) {
            PlusView(model: plus, member: model)
        }
        // 略過後在通知步驟開通了 Plus(經推入的付費牆):解鎖通知,回到這一步。
        .onChange(of: plus.isPlusActive) { _, isActive in
            guard isActive, entry.join.skippedPlus else { return }
            entry.plusActivated()
            showingPlus = false
        }
    }

    // MARK: 第 2 步:開通 Plus

    private var selectedPlan: PlusPlan? {
        plus.plans.first { $0.id == selectedPlanID } ?? plus.defaultPlan
    }

    private var paywallPage: some View {
        List {
            SubscriptionNoticeSection(plus: plus)
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activate Purrdr Plus").font(.title2.bold())
                    Text("Plus gives you notifications and host sync. Chat and terminal aren’t affected.")
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 4, trailing: 4))
            }
            switch plus.storefront {
            case .loading:
                Section { PlanOptionsSkeleton(identifier: "account.join.storefront.loading") }
            case .paymentsDisabled:
                Section {
                    Label("Purchases aren’t allowed on this device, for example because of Screen Time. You can still restore a subscription you already have.", systemImage: "lock")
                        .accessibilityIdentifier("account.join.paymentsDisabled")
                }
            case .unavailable:
                Section {
                    Text("Couldn’t load subscription options. Check your connection and try again.")
                    Button("Try Again") { Task { await plus.loadPlans() } }
                        .listAction()
                }
            case .available:
                Section {
                    ForEach(plus.plans) { plan in
                        PlanRow(plan: plan, isSelected: plan.id == selectedPlan?.id) { selectedPlanID = plan.id }
                    }
                } footer: {
                    if let plan = selectedPlan {
                        Text(plan.disclosure)
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("account.join.disclosure")
                    }
                }
            }
        }
        .appGroupedList()
        .accessibilityIdentifier("account.join.paywall")
        .disabled(plus.isWorking)
        .task { await plus.loadPlans() }
        .alert(plus.notice?.title ?? "", isPresented: noticePresented, presenting: plus.notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 2) {
                if plus.storefront == .available {
                    primaryButton(selectedPlan?.freeTrial == nil ? "Subscribe" : "Start Free Trial") { subscribe() }
                        .disabled(selectedPlan == nil || signedInMember == nil)
                        .accessibilityIdentifier("account.join.primary")
                }
                Button("Not Now") { entry.skipPlus() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("account.join.secondary")
                HStack(spacing: 4) {
                    Button("Restore Purchases") { restore() }
                        .accessibilityIdentifier("account.join.restore")
                    Link("Terms of Use", destination: PurrdrLinks.termsOfUse)
                    Link("Privacy Policy", destination: PurrdrLinks.privacyPolicy)
                }
                .font(.footnote)
                .buttonStyle(.borderless)
                .lineLimit(2)
                .frame(minHeight: 44)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { plus.notice.map { !$0.isInformational } ?? false }, set: { if !$0 { plus.notice = nil } })
    }

    private func subscribe() {
        guard let plan = selectedPlan, let member = signedInMember else { return }
        Task {
            await plus.purchase(planID: plan.id, member: member)
            advanceIfActive()
        }
    }

    private func restore() {
        Task {
            await plus.restore()
            advanceIfActive()
        }
    }

    /// 開通成功:歡迎提示不重複彈(流程本身就是歡迎),前進到下一步。
    private func advanceIfActive() {
        guard plus.isPlusActive, step == .activatePlus, entry.join.step == .activatePlus else { return }
        if plus.notice == .welcome || plus.notice == .restored { plus.notice = nil }
        entry.advance()
    }

    // MARK: 第 3 步:開啟通知

    private var notificationsPage: some View {
        let locked = entry.join.notificationsAction != .unlocked
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Turn On Notifications").font(.title2.bold())
                    Text(locked
                        ? "Notifications need Purrdr Plus. You chose to activate it later, so this step is skipped for now."
                        : "Get notified when an agent needs you or finishes. Turn it on per host. You can change it later in the Hosts tab.")
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 4, trailing: 4))
            }
            Section {
                if pushes.isEmpty {
                    ContentUnavailableView(
                        "No Hosts Yet", systemImage: "desktopcomputer",
                        description: Text("Add one in the Hosts tab, then turn on notifications there."))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("account.join.noHosts")
                }
                ForEach(pushes) { push in
                    if locked {
                        LockedHostRow(push: push)
                    } else {
                        HostPushRow(push: push, pair: { _ in })
                    }
                }
            } footer: {
                if !locked {
                    Text("Turning on a host installs a notification helper on it. You can remove it completely.")
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .appGroupedList()
        .accessibilityIdentifier(locked ? "account.join.notificationsLocked" : "account.join.notifications")
        .hostPushConfirmation(pushes)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 2) {
                if locked {
                    primaryButton("Activate Purrdr Plus") { showingPlus = true }
                        .accessibilityIdentifier("account.join.primary")
                    Button("Done for Now") { entry.advance() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("account.join.secondary")
                } else {
                    primaryButton("Continue") { entry.advance() }
                        .accessibilityIdentifier("account.join.primary")
                    Button("Skip") { entry.advance() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("account.join.secondary")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: 第 4 步:同步主機

    private var syncPage: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync Host List").font(.title2.bold())
                    Text("See the same hosts on every iPhone, iPad, and Android device where you’re signed in to this member account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 4, trailing: 4))
            }
            Section {
                if let hostSync {
                    Toggle(isOn: Binding(get: { hostSync.isEnabled }, set: { on in Task { await hostSync.setEnabled(on) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync Host List")
                            Text("\(hostCount) hosts")
                                .font(.subheadline)
                                .foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("account.join.sync")
                    if case .failed(let message) = hostSync.status {
                        Text(verbatim: message).foregroundStyle(.secondaryText)
                    }
                }
            } footer: {
                Text("Only names, addresses, and connection methods sync. Keys, passwords, and pairing tokens always stay on this device.")
                    .foregroundStyle(.secondaryText)
            }
        }
        .appGroupedList()
        .accessibilityIdentifier("account.join.syncPage")
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 2) {
                primaryButton("Finish Setup") { entry.advance() }
                    .accessibilityIdentifier("account.join.primary")
                Button("Skip") { entry.advance() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("account.join.secondary")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: 完成

    private var donePage: some View {
        let created = entry.join.completion == .memberCreated
        let notifying = pushes.notifyingHostNames
        return ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .padding(.top, 60)
                Text(created ? "Member Created" : "Setup Complete")
                    .font(.title2.bold())
                VStack(spacing: 4) {
                    if created {
                        Text("You can activate Purrdr Plus later in Account. Notifications and host sync need it.")
                    } else {
                        Text("Purrdr Plus is on.")
                        if !notifying.isEmpty {
                            Text("Notifications are on for \(notifying.formatted(.list(type: .and))).")
                        }
                        if hostSync?.isEnabled == true {
                            Text("Your host list syncs to your other devices.")
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier(created ? "account.join.doneCreated" : "account.join.done")
        .safeAreaBar(edge: .bottom) {
            primaryButton("Get Started") { entry.finish() }
                .accessibilityIdentifier("account.join.primary")
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .filledProminentButtonStyle()
        .buttonBorderShape(.capsule)
    }
}

/// 沒有 Plus 時的通知列:主機名稱、「需要 Purrdr Plus」與鎖頭(不是開關,不會誤以為已開啟)。
private struct LockedHostRow: View {
    let push: HostPush

    var body: some View {
        HStack(spacing: 12) {
            HostIconBadge(push.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: push.name)
                Text("Needs Purrdr Plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
            Spacer(minLength: 8)
            Image(systemName: "lock")
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account.join.locked.\(push.host.storedValue)")
    }
}
