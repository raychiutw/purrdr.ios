import AuthenticationServices
import PurrdrCore
import SwiftUI

/// 帳號 sheet(#246;聊天列表右上角的帳號鈕開啟):頭像與名稱、「設定 Purrdr Plus」步驟卡、登入方式、登出、刪除會員。
///
/// 聊天與終端機不需要會員或訂閱，這個畫面不會擋在任何功能前面。
public struct MemberView: View {
    @Bindable var model: MemberModel
    /// `nil` 時不顯示步驟卡與 Purrdr Plus。
    let plus: SubscriptionModel?
    /// 每台主機的推播開關(步驟三與「通知」區塊)。
    let pushes: [HostPush]
    /// 會員名下收通知的裝置(「通知裝置」區塊)。
    let pushDevices: PushDevicesModel?
    /// 主機同步(步驟四)。
    let hostSync: HostSyncModel?
    /// 還沒配對的 HTTPS 主機在通知列開配對(#295;與主機頁同一個編輯器)。
    let hosts: HostsModel?
    /// 設定(#503):外觀、App 鎖等併在第一層;`nil` 時不顯示。
    let settings: AccountSettings?
    /// 沒登入時的流程(#408):選擇、登入、加入。
    @State private var entry = AccountEntryFlow()
    @Environment(\.dismiss) private var dismiss

    init(
        model: MemberModel, plus: SubscriptionModel? = nil, pushes: [HostPush] = [], pushDevices: PushDevicesModel? = nil,
        hostSync: HostSyncModel? = nil, hosts: HostsModel? = nil, settings: AccountSettings? = nil
    ) {
        self.settings = settings
        self.model = model
        self.plus = plus
        self.pushes = pushes
        self.pushDevices = pushDevices
        self.hostSync = hostSync
        self.hosts = hosts
    }

    public var body: some View {
        NavigationStack {
            MemberContent(
                model: model, plus: plus, pushes: pushes, pushDevices: pushDevices, hostSync: hostSync, hosts: hosts,
                settings: settings, entry: $entry
            )
            .toolbar {
                if entry.shownScreen(phase: model.phase, hasPlus: plus != nil) != nil {
                    AccountEntryToolbar(entry: $entry, onClose: { dismiss() })
                } else {
                    SheetCloseToolbar(identifier: "member.close")
                }
            }
        }
    }
}

/// 帳號頁的內容(不含 NavigationStack 與「完成」)。
public struct MemberContent: View {
    @Bindable var model: MemberModel
    let plus: SubscriptionModel?
    let pushes: [HostPush]
    let pushDevices: PushDevicesModel?
    let hostSync: HostSyncModel?
    let hosts: HostsModel?
    let settings: AccountSettings?
    @Binding var entry: AccountEntryFlow

    init(
        model: MemberModel, plus: SubscriptionModel? = nil, pushes: [HostPush] = [], pushDevices: PushDevicesModel? = nil,
        hostSync: HostSyncModel? = nil, hosts: HostsModel? = nil, settings: AccountSettings? = nil, entry: Binding<AccountEntryFlow>
    ) {
        self.settings = settings
        self.model = model
        self.plus = plus
        self.pushes = pushes
        self.pushDevices = pushDevices
        self.hostSync = hostSync
        self.hosts = hosts
        self._entry = entry
    }

    public var body: some View {
        content
            // 登入頁查無這個帳號的會員:擋下並問要不要加入,確認才進加入流程(#434)。掛在 content 上,與下面的 notice alert 分開。
            .alert("No Member Found", isPresented: Binding(get: { model.memberNotFound }, set: { if !$0 { model.dismissMemberNotFound() } })) {
                Button("Join") { entry.switchToJoin() }
                    .accessibilityIdentifier("member.notFound.join")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("We couldn’t find a member for this account. Do you want to join?")
            }
            .navigationTitle(entry.navigationTitle(phase: model.phase, hasPlus: plus != nil))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        .task {
            if model.phase == .unknown { await model.restore() }
        }
        // 登入結果決定下一頁:登入進帳號頁、加入進步驟(#408)。
        .onChange(of: model.lastSignIn) { _, event in
            guard let event else { return }
            entry.signedIn(memberCreated: event.memberCreated)
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .signedOut { entry.reset() }
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
    }

    @ViewBuilder
    private var content: some View {
        if let screen = entry.shownScreen(phase: model.phase, hasPlus: plus != nil) {
            // 沒登入先選「登入」或「加入會員」(#408);加入第 2 步起是步驟流程。
            if screen == .join, entry.join.step != .createMember, let plus {
                JoinFlowPages(
                    model: model, entry: $entry, plus: plus, pushes: pushes, hostSync: hostSync, hostCount: hosts?.hosts.count ?? 0,
                    signedInMember: signedInMember)
            } else {
                AccountEntryPages(model: model, entry: $entry, settings: settings)
            }
        } else if model.phase == .unknown {
            if model.isWorking {
                // 後台還沒回應、沒有上次的會員資料:帳號頁骨架(#496)。
                AccountSkeletonView(settings: settings)
            } else {
                // 連不上後台:說明加上設定區(設定不被後台狀態擋住)。
                List {
                    Section {
                        ContentUnavailableView {
                            Label("Can’t Reach Purrdr", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text("Your sign-in is kept on this device. Try again when you’re online.")
                        } actions: {
                            Button("Try Again") { Task { await model.restore() } }
                        }
                        .listRowBackground(Color.clear)
                    }
                    if let settings { SettingsSections(settings) }
                }
                .appGroupedList()
            }
        } else {
            AccountView(model: model, plus: plus, pushes: pushes, pushDevices: pushDevices, hostSync: hostSync, hosts: hosts, settings: settings)
        }
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    private var signedInMember: Member? {
        if case .signedIn(let member) = model.phase { return member }
        return nil
    }
}

/// 只有登入的 sheet(付費牆的「登入以訂閱」):先選登入或加入,登入完成就自動關閉。
struct SignInSheet: View {
    let model: MemberModel
    @State private var entry = AccountEntryFlow()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountEntryPages(model: model, entry: $entry)
                .navigationTitle(entry.navigationTitle(phase: model.phase, hasPlus: false))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { AccountEntryToolbar(entry: $entry, onClose: { dismiss() }) }
        }
        .onChange(of: model.phase) { _, phase in
            if case .signedIn = phase { dismiss() }
        }
    }
}

// MARK: - 登入

/// Sign in with Apple 與 Google 按鈕：同寬、同高、同圓角(Apple 按鈕不得小於其他登入按鈕)。
struct SignInButtons: View {
    let model: MemberModel
    let linking: Bool
    let methods: [SignInMethod]
    /// 登入頁「登入」、加入頁「註冊」的按鈕說法(連結另一種方式時是「繼續」)。
    var copy: AccountEntryFlow.SignInCopy = .signIn

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.usesTestingSignIn) private var usesTestingSignIn
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    /// 跟著字級放大，但最高 88 pt,免得 AX 字級時把說明擠出畫面。
    @ScaledMetric(relativeTo: .body) private var scaledHeight: CGFloat = 50
    private var height: CGFloat { min(max(scaledHeight, 50), 88) }
    static let cornerRadius: CGFloat = 25

    var body: some View {
        VStack(spacing: 12) {
            ForEach(methods, id: \.self) { method in
                if usesTestingSignIn {
                    testingButton(method)
                } else {
                    switch method {
                    case .apple: appleButton
                    case .google: googleButton
                    }
                }
            }
        }
        .disabled(model.isWorking)
    }

    private var googleTitle: LocalizedStringKey {
        if linking { return "Continue with Google" }
        return copy == .signUp ? "Sign Up with Google" : "Sign in with Google"
    }

    /// UI 測試:不開系統登入,直接以固定憑證登入假後台(註冊頁的憑證讓假後台新建會員,登入頁的是既有會員)。
    private func testingButton(_ method: SignInMethod) -> some View {
        Button {
            let credential = SignInCredential(
                method: method, idToken: copy == .signUp ? "ui-testing-new" : "ui-testing-existing", nonce: "ui-testing",
                authorizationCode: method == .apple ? "ui-testing" : nil)
            Task {
                if linking { await model.link(with: credential) } else { await model.signIn(with: credential, joining: copy == .signUp) }
            }
        } label: {
            Text(method == .apple ? (copy == .signUp ? "Sign up with Apple" : "Sign in with Apple") : googleTitle)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .foregroundStyle(.primary)
                .background(AppSurface.page, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
                .contentShape(Capsule())
        }
        .accessibilityIdentifier(method == .apple ? "member.signIn.apple" : "member.signIn.google")
    }

    private var appleButton: some View {
        SignInWithAppleButton(linking ? .continue : (copy == .signUp ? .signUp : .signIn)) { request in
            request.requestedScopes = [.email]
            request.nonce = model.beginAppleAuthorization(linking: linking, joining: copy == .signUp)
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let idToken = credential.identityToken.map({ String(decoding: $0, as: UTF8.self) }),
                      let code = credential.authorizationCode.map({ String(decoding: $0, as: UTF8.self) }) else {
                    model.appleAuthorizationFailed(canceled: false)
                    return
                }
                Task { await model.completeAppleAuthorization(idToken: idToken, authorizationCode: code) }
            case .failure(let error):
                model.appleAuthorizationFailed(canceled: (error as? ASAuthorizationError)?.code == .canceled)
            }
        }
        // 淺色背景用 black,深色背景用 white(HIG:black 不可放在深色背景)。
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .clipShape(Capsule())
        .accessibilityIdentifier("member.signIn.apple")
    }

    private var googleButton: some View {
        Button {
            Task {
                let browser: GoogleSignIn.Browser = { url, scheme in
                    do {
                        return try await webAuthenticationSession.authenticate(
                            using: url,
                            callback: .customScheme(scheme),
                            preferredBrowserSession: .ephemeral,
                            additionalHeaderFields: [:]
                        )
                    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                        throw GoogleSignInError.canceled
                    }
                }
                if linking {
                    await model.linkGoogle(browser: browser)
                } else {
                    await model.signInWithGoogle(browser: browser, joining: copy == .signUp)
                }
            }
        } label: {
            Text(googleTitle)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .foregroundStyle(.primary)
                .background(AppSurface.page, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard(cornerRadius: Self.cornerRadius))
        .accessibilityIdentifier("member.signIn.google")
    }
}

// MARK: - 帳號頁

/// 帳號頁(#409、設計稿第 27 組):會員資訊、Purrdr Plus 卡(各狀態)、Plus 功能(沒有 Plus 時鎖定但列仍可點並說明)、
/// 通知裝置、登入方式、登入中的裝置、登出、刪除會員。
struct AccountView: View {
    let model: MemberModel
    let plus: SubscriptionModel?
    let pushes: [HostPush]
    let pushDevices: PushDevicesModel?
    let hostSync: HostSyncModel?
    let hosts: HostsModel?
    let settings: AccountSettings?
    @State private var confirmingDeletion = false
    @State private var confirmingSignOut = false
    /// 刪除會員前先處理訂閱的頁面(#412):有仍會扣款的訂閱才出現。
    @State private var deletionSubscription: DeletionSubscriptionNotice?
    @State private var showingDeletionSubscription = false
    /// 在訂閱說明頁選了「繼續刪除會員」:等頁面退回帳號頁後才跳確認(同時退頁與跳 alert 會被 SwiftUI 吞掉)。
    @State private var continuedDeletion = false
    @State private var showingPlus = false
    /// 程式要開通知頁時用(「全部開啟」、Purrdr Plus 頁點通知);點列本身走 NavigationLink。
    @State private var showingNotifications = false
    @State private var managingSubscription = false
    @State private var offeringFeatureSetup = false
    /// 點了鎖定的功能列:說明原因與下一步。
    @State private var lockedFeature: AccountFeature?
    /// Purrdr Plus 頁點功能列後捲到帳號頁對應的區塊(#323)。
    @State private var featureScrollRequest: PlusFeature?

    private var signedInMember: Member? {
        if case .signedIn(let member) = model.phase { return member }
        return nil
    }

    private var notifyingHostNames: [String] { pushes.notifyingHostNames }

    private var account: AccountState {
        AccountState(authentication: signedInMember != nil ? .signedIn : .signedOut, plus: plus?.plusStatus ?? .none)
    }

    private var plusFeatures: PlusFeatureLinks {
        PlusFeatureLinks(
            status: PlusFeatureStatus(
                notifyingHostCount: notifyingHostNames.count,
                isHostSyncOn: hostSync?.isEnabled ?? false,
                deviceCount: pushDevices.flatMap { $0.hasLoaded ? $0.devices.count : nil }),
            dismissesOnOpen: true,
            open: { featureScrollRequest = $0 })
    }

    private var progress: AccountSetupProgress? {
        plus.map { AccountSetupProgress(member: model, plus: $0, isNotificationsOn: !notifyingHostNames.isEmpty, hostSync: hostSync) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: featureScrollRequest) { _, feature in
                    guard let feature else { return }
                    featureScrollRequest = nil
                    if feature == .notifications, account.hasPlus {
                        showingNotifications = true
                    } else {
                        withAnimation { proxy.scrollTo(feature, anchor: .top) }
                    }
                }
        }
    }

    private var list: some View {
        List {
            Section {
                AccountHeader(member: signedInMember)
            }

            if model.isConnectionLimited {
                // 後台暫時連不上(#406):登入仍然有效,不是被登出。
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Can’t reach Purrdr for now. You’re still signed in.", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondaryText)
                        Button("Try Again") { Task { await model.restore() } }
                            .accessibilityIdentifier("account.connectionLimited.retry")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("account.connectionLimited")
                }
            }

            if let plus {
                if let subscription = plus.subscription, subscription.pendingReview {
                    Section {
                        ErrorLabel(String(localized: "Your two old members were combined. Another subscription (\(subscription.store.displayName)) needs your attention: cancel it there to avoid paying twice."))
                        .accessibilityIdentifier("account.pendingReview")
                    }
                }
                plusSection(plus: plus)
                featureSections(plus: plus)
                if signedInMember != nil, let pushDevices {
                    // 訂閱到期也顯示：仍可遠端關閉遺失的裝置。
                    Section {
                        NavigationLink {
                            PushDevicesView(model: pushDevices, canRename: account.hasPlus)
                        } label: {
                            LabeledContent("Notification Devices") {
                                if pushDevices.hasLoaded { Text("\(pushDevices.devices.count) devices") }
                            }
                        }
                        .accessibilityIdentifier("member.pushDevices")
                    } header: {
                        Text("Notification Devices")
                            .foregroundStyle(.secondaryText)
                    }
                    .id(PlusFeature.devices)
                }
            }

            if let settings { SettingsSections(settings) }

            if let member = signedInMember {
                Section {
                    NavigationLink {
                        SignInMethodsView(model: model, member: member)
                    } label: {
                        LabeledContent("Sign-In Methods") {
                            Text(verbatim: member.identities.map(\.method.shortName).formatted(.list(type: .and)))
                        }
                    }
                    .accessibilityIdentifier("member.signInMethods")
                    NavigationLink {
                        SignInDevicesView(model: model.signInDevices)
                    } label: {
                        LabeledContent("Signed-In Devices") {
                            if let count = model.signInDevices.devices?.count {
                                Text("\(count) devices")
                            }
                        }
                    }
                    .accessibilityIdentifier("member.signInDevices")
                }
                Section {
                    Button("Sign Out") { confirmingSignOut = true }
                        .accessibilityIdentifier("member.signOut")
                    Button("Delete Member", role: .destructive) { startDeletion() }
                        .accessibilityIdentifier("member.delete")
                }
            }
        }
        .appGroupedList()
        .accessibilityIdentifier("sheet.account")
        .disabled(model.isWorking)
        .navigationDestination(isPresented: $showingNotifications) { notificationsPage }
        .navigationDestination(isPresented: $showingPlus) {
            if let plus {
                PlusView(model: plus, member: model, features: plusFeatures)
            }
        }
        .onChange(of: progress) { previous, current in
            // 只有從這裡進付費牆開通才問;開帳號頁時讀回訂閱不算剛開通。
            guard showingPlus, let previous, let current, current.offersFeatureSetup(after: previous) else { return }
            showingPlus = false
            offeringFeatureSetup = true
        }
        .task(id: signedInMember?.id) {
            await plus?.refresh()
            await model.signInDevices.load()
        }
        .manageSubscriptions(isPresented: $managingSubscription)
        .pushDevicesLoading(signedInMember != nil ? pushDevices : nil, notifyingHostNames: notifyingHostNames)
        .alert(plus?.notice?.title ?? "", isPresented: subscriptionNoticePresented, presenting: plus?.notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .alert(
            Text(verbatim: lockReason?.shortText ?? ""), isPresented: lockedPresented, presenting: lockReason
        ) { reason in
            switch reason {
            case .plusRequired, .subscriptionEnded:
                Button("Purrdr Plus") { showingPlus = true }
                    .accessibilityIdentifier("account.locked.openPlus")
            default:
                EmptyView()
            }
            Button("OK", role: .cancel) {}
                .accessibilityIdentifier("account.locked.ok")
        } message: { reason in
            Text(verbatim: reason.explanation)
        }
        .alert("Purrdr Plus Is On", isPresented: $offeringFeatureSetup) {
            Button("Later", role: .cancel) {}
            Button("Turn On All") { turnOnAll() }
                .accessibilityIdentifier("account.turnOnAll")
        } message: {
            Text("Turn on notifications and host sync now? You can change them later.")
        }
        .alert("Sign Out?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
                .accessibilityIdentifier("member.signOut.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signing out turns off notifications for this device and pauses host sync. Hosts and chats keep working — they don’t need a member account.")
        }
        .navigationDestination(isPresented: $showingDeletionSubscription) {
            if let deletionSubscription {
                DeletionSubscriptionView(
                    notice: deletionSubscription,
                    manage: { managingSubscription = true },
                    proceed: {
                        continuedDeletion = true
                        showingDeletionSubscription = false
                    })
            }
        }
        .onChange(of: showingDeletionSubscription) { _, showing in
            guard !showing, continuedDeletion else { return }
            continuedDeletion = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                confirmingDeletion = true
            }
        }
        .alert("Delete Member?", isPresented: $confirmingDeletion) {
            Button("Delete Member", role: .destructive) { Task { await model.deleteMember() } }
                .accessibilityIdentifier("member.delete.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.canVerifyOwner {
                Text("Your member account, synced hosts, and notifications on all your devices will be deleted from the server. This can’t be undone.")
            } else {
                Text("Your member account, synced hosts, and notifications on all your devices will be deleted from the server. This can’t be undone. This device has no passcode, so Purrdr can’t verify it’s you; confirming here is enough.")
            }
        }
    }

    /// 刪除會員:有仍會扣款的訂閱先處理訂閱(Apple／Google 會繼續收費),沒有才直接問刪除確認(#412)。
    private func startDeletion() {
        if let notice = DeletionSubscriptionNotice(subscription: plus?.subscription) {
            deletionSubscription = notice
            showingDeletionSubscription = true
        } else {
            confirmingDeletion = true
        }
    }

    /// 付費牆(PlusView)開著時它自己顯示提示,帳號頁不重複顯示。
    private var subscriptionNoticePresented: Binding<Bool> {
        Binding(
            get: { plus?.notice != nil && !showingPlus },
            set: { if !$0 { plus?.notice = nil } })
    }

    private var lockReason: FeatureLockReason? {
        guard let lockedFeature, case .locked(let reason) = account.availability(of: lockedFeature) else { return nil }
        return reason
    }

    private var lockedPresented: Binding<Bool> {
        Binding(get: { lockedFeature != nil && lockReason != nil }, set: { if !$0 { lockedFeature = nil } })
    }

    private func plusSection(plus: SubscriptionModel) -> some View {
        Section {
            PlusCardView(
                card: plus.plusCard, subscription: plus.subscription, isWorking: plus.isWorking || model.isWorking,
                perform: { perform($0, plus: plus) }, manage: { managingSubscription = true })
        } header: {
            Text("Purrdr Plus")
                .foregroundStyle(.secondaryText)
        } footer: {
            Text("Chat and terminal don’t need a member account or subscription.")
                .foregroundStyle(.secondaryText)
        }
    }

    private var notificationsPage: some View {
        AccountNotificationsView(pushes: pushes, openPlus: { showingPlus = true }, hosts: hosts)
    }

    /// 「Plus 功能」區(設計稿第 27 組):主機同步與通知併在同一區。
    /// 有 Plus:主機同步是開關、通知推入逐台主機的開關頁;沒有:鎖定列(文字對比 ≥ 4.5:1,列仍可點並說明原因)。
    @ViewBuilder
    private func featureSections(plus: SubscriptionModel) -> some View {
        if account.hasPlus {
            Section {
                if let hostSync {
                    HostSyncRows(model: hostSync, plus: plus, member: model)
                        .id(PlusFeature.hostSync)
                }
                NavigationLink {
                    notificationsPage
                } label: {
                    LabeledContent("Notifications") {
                        Text(verbatim: plusFeatures.status.value(for: .notifications) ?? "")
                    }
                }
                .accessibilityIdentifier("account.notifications")
                .id(PlusFeature.notifications)
            } header: {
                Text("Plus Features")
                    .foregroundStyle(.secondaryText)
            } footer: {
                if hostSync != nil {
                    Text(HostSyncRows.footer)
                        .foregroundStyle(.secondaryText)
                }
            }
        } else if signedInMember != nil {
            Section {
                lockedRow(.hostSync, symbol: "arrow.triangle.2.circlepath", title: "Host Sync", identifier: "account.locked.hostSync")
                lockedRow(.notifications, symbol: "bell.badge", title: "Notifications", identifier: "account.locked.notifications")
            } header: {
                Text("Plus Features")
                    .foregroundStyle(.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func lockedRow(_ feature: AccountFeature, symbol: String, title: LocalizedStringKey, identifier: String) -> some View {
        if case .locked(let reason) = account.availability(of: feature) {
            LockedFeatureRow(symbol: symbol, title: title, reason: reason, identifier: identifier) { lockedFeature = feature }
        }
    }

    private func perform(_ button: PlusCard.Button, plus: SubscriptionModel) {
        switch button {
        case .activatePlus, .renew: showingPlus = true
        case .restorePurchases: Task { await plus.restore() }
        case .transferSubscription: Task { await plus.transferSubscription() }
        case .updatePaymentMethod: managingSubscription = true
        case .retry: Task { await plus.refresh() }
        }
    }

    /// 開通後的「全部開啟」:同步直接開;只有一台能開通知的主機時直接開(仍經安裝確認),否則捲到「通知」讓使用者挑。
    private func turnOnAll() {
        Task { await hostSync?.setEnabled(true) }
        let supported = pushes.filter { $0.support == .supported }
        if supported.count == 1, let only = supported.first {
            // 確認對話框在通知頁上:先推入頁面,等轉場結束再請求。
            showingNotifications = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                await only.model.requestOn()
            }
        } else {
            showingNotifications = true
        }
    }
}

extension AccountSetupProgress {
    /// 由會員、訂閱、通知(至少一台主機開啟)與主機同步的目前狀態組成(#246、#263);帳號頁用它判斷剛開通時要不要問「全部開啟」。
    @MainActor
    init(member: MemberModel, plus: SubscriptionModel, isNotificationsOn: Bool, hostSync: HostSyncModel?) {
        let isMember = if case .signedIn = member.phase { true } else { false }
        self.init(
            account: AccountState(authentication: isMember ? .signedIn : .signedOut, plus: PlusStatus(subscription: plus.subscription)),
            isNotificationsOn: isNotificationsOn,
            isHostSyncOn: hostSync?.isEnabled == true)
    }
}

extension MemberSubscription.Store {
    var displayName: String {
        switch self {
        case .appStore: String(localized: "App Store")
        case .googlePlay: String(localized: "Google Play")
        }
    }
}

/// 登入中的裝置(#409):每支裝置一列,可撤銷其他裝置(= 把它登出,要先確認是本人)。
struct SignInDevicesView: View {
    @Bindable var model: SignInDevicesModel

    var body: some View {
        List {
            Section {
                if let devices = model.devices {
                    ForEach(devices) { device in
                        SignInDeviceRow(device: device, isBusy: model.busyDeviceIDs.contains(device.id)) {
                            model.pendingRevoke = device
                        }
                    }
                } else if model.problem == nil {
                    ProgressView()
                }
                if let problem = model.problem {
                    ErrorLabel(problem)
                        .accessibilityIdentifier("account.signInDevices.problem")
                    Button("Try Again") { Task { await model.load() } }
                }
            } footer: {
                Text("Signing out another device means it has to sign in again. To sign out this device, use Sign Out on the account page.")
                    .foregroundStyle(.secondaryText)
            }
        }
        .appGroupedList()
        .accessibilityIdentifier("account.signInDevices")
        .navigationTitle("Signed-In Devices")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
        .confirmationDialog(
            Text(verbatim: model.pendingRevoke.map { String(localized: "Sign out \($0.displayName)?") } ?? ""),
            isPresented: Binding(get: { model.pendingRevoke != nil }, set: { if !$0 { model.pendingRevoke = nil } }),
            titleVisibility: .visible, presenting: model.pendingRevoke
        ) { device in
            Button("Sign Out", role: .destructive) { Task { await model.revoke(device) } }
                .accessibilityIdentifier("account.signInDevices.confirm")
        } message: { _ in
            Text("This device will have to sign in again.")
        }
    }
}

private struct SignInDeviceRow: View {
    let device: SignInDevice
    let isBusy: Bool
    let signOut: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.model == "iPad" ? "ipad" : "iphone")
                .frame(width: 28)
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: device.displayName)
                let model = device.name == nil ? nil : device.model
                Group {
                    if device.isCurrent {
                        if let model { Text("This device · \(model)") } else { Text("This device") }
                    } else if let model {
                        Text("Last active \(device.lastActiveAt.formatted(.relative(presentation: .named))) · \(model)")
                    } else {
                        Text("Last active \(device.lastActiveAt.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if !device.isCurrent {
                Button("Sign Out", role: .destructive, action: signOut)
                    .disabled(isBusy)
                    .accessibilityIdentifier("account.signInDevice.signOut.\(device.id)")
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.signInDevice.\(device.id)")
    }
}

extension SignInDevice {
    var displayName: String {
        name ?? model ?? String(localized: "Unnamed Device")
    }
}

/// 帳號頁頂端一列(設計稿第 27 組):小頭像、email 與登入方式摘要;未加入會員顯示人頭圖。
private struct AccountHeader: View {
    let member: Member?

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatar(member: member)
                .font(.title3)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let member {
                        if let name = member.accountName {
                            Text(verbatim: name)
                        } else {
                            Text("Purrdr Member")
                        }
                    } else {
                        Text("Not a Member Yet")
                    }
                }
                .fontWeight(.semibold)
                if let member, !member.identities.isEmpty {
                    Text(verbatim: member.identities.map(\.method.shortName).formatted(.list(type: .and)))
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 帳號頭像：主色填色(`prominentFill`)圓底上的頭像字;沒有字時用人像符號，未加入會員(`nil`)用系統人頭圖。帳號鈕與帳號頁共用。
struct AccountAvatar: View {
    let member: Member?

    var body: some View {
        Group {
            if let member {
                ZStack {
                    Circle().fill(.prominentFill)
                    Group {
                        if let initial = member.avatarInitial {
                            Text(verbatim: initial)
                        } else {
                            Image(systemName: "person.fill")
                        }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(.onProminentFill)
                }
            } else {
                // 沒登入:系統人頭圖(圖示而非文字，AX 字級時帳號鈕收進溢出選單，選單項目不會把畫面上的符號當名稱)。
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.light)
                    .foregroundStyle(.secondaryText)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 登入方式(#410、設計稿第 28 組):已綁定的方式與移除(至少保留一種)、新增另一種;
/// 新增、移除、合併都要先確認身分。新增時發現已屬另一個會員,出合併確認頁(兩邊摘要)。
struct SignInMethodsView: View {
    @Bindable var model: MemberModel
    let member: Member
    @State private var removing: SignInMethod?

    var body: some View {
        List {
            Section {
                ForEach(member.identities, id: \.method) { identity in
                    LabeledContent {
                        if member.identities.count > 1 {
                            Button("Remove", role: .destructive) { removing = identity.method }
                                .accessibilityLabel(Text("Remove \(identity.method.displayName)"))
                                .accessibilityIdentifier("member.identity.remove.\(identity.method.rawValue)")
                        }
                    } label: {
                        Text(verbatim: identity.method.shortName)
                        if let email = identity.email {
                            Text(verbatim: email)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("member.identity.\(identity.method.rawValue)")
                }
            } footer: {
                Text("Keep at least one sign-in method. Adding or removing one asks you to confirm it’s you.")
            }

            let unlinked = SignInMethod.allCases.filter { member.identity($0) == nil }
            if !unlinked.isEmpty {
                Section {
                    SignInButtons(model: model, linking: true, methods: unlinked)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    Text("Add Sign-In Method")
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .appGroupedList()
        .disabled(model.isWorking)
        .navigationTitle("Sign-In Methods")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            removing.map { Text("Remove \($0.displayName)?") } ?? Text(verbatim: ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing
        ) { method in
            Button("Remove", role: .destructive) { Task { await model.unlink(method) } }
                .accessibilityIdentifier("member.identity.remove.confirm")
        } message: { method in
            Text("You won’t be able to sign in with \(method.displayName) anymore. You’ll confirm it’s you next.")
        }
        .sheet(isPresented: Binding(get: { model.pendingMerge != nil }, set: { if !$0 { model.cancelMerge() } })) {
            if let proposal = model.pendingMerge {
                MergeConfirmView(model: model, summary: proposal.summary)
                    .appSheetBackground()
            }
        }
    }
}

/// 合併確認頁(設計稿第 28 組「新增 Google 時發現已是會員」):兩邊的摘要,確認後才合併。
struct MergeConfirmView: View {
    let model: MemberModel
    let summary: MemberMergeSummary

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This Account Is Already a Member")
                            .font(.title3.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text("That sign-in method already belongs to another member. Combine the two members into one? Both methods will then sign in to the same member, and their hosts and notification devices are combined.")
                            .font(.subheadline)
                            .foregroundStyle(.secondaryText)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    MergeSideRow(title: "This member", side: summary.current)
                        .accessibilityIdentifier("member.merge.current")
                    MergeSideRow(title: "The other member", side: summary.other)
                        .accessibilityIdentifier("member.merge.other")
                } footer: {
                    if !summary.canMerge {
                        Text("Members that both have an active subscription can’t be combined. Cancel one of them first.")
                            .accessibilityIdentifier("member.merge.blocked")
                    }
                }
                Section {} footer: {
                    Text("You’ll confirm it’s you before the members are combined.")
                }
            }
            .appGroupedList()
            .navigationTitle("Add Sign-In Method")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                SheetCloseToolbar(identifier: "member.merge.cancel") { model.cancelMerge() }
                ModalConfirmToolbar(
                    title: "Combine", identifier: "member.merge.confirm",
                    isEnabled: summary.canMerge && !model.isWorking
                ) { Task { await model.confirmMerge() } }
            }
            .accessibilityIdentifier("sheet.merge")
        }
    }
}

private struct MergeSideRow: View {
    let title: LocalizedStringKey
    let side: MemberMergeSummary.Side

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
            Text(verbatim: side.identities.map { identity in
                [identity.method.shortName, identity.email].compactMap { $0 }.joined(separator: " ")
            }.formatted(.list(type: .and)))
            Text(verbatim: details)
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [side.hasActiveSubscription ? String(localized: "Has Purrdr Plus") : String(localized: "No subscription")]
        if side.hostCount > 0 { parts.append(String(localized: "\(side.hostCount) hosts")) }
        return parts.joined(separator: " · ")
    }
}

extension SignInMethod {
    /// 帳號頁摘要用的短名稱(「Apple、Google」)。
    var shortName: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        }
    }

    var displayName: String {
        switch self {
        case .apple: String(localized: "Sign in with Apple")
        case .google: "Google"
        }
    }
}

extension MemberNotice {
    var title: LocalizedStringKey {
        switch self {
        case .failed: "Couldn’t Finish"
        case .subscriptionConflict: "Can’t Combine Members"
        case .subscriptionInUse: "Subscription Belongs to Another Member"
        case .methodAlreadyLinked: "Already Linked"
        case .merged: "Members Combined"
        case .autoLinked: "Signed In to Your Existing Member"
        case .deleted: "Member Deleted"
        case .signedOut: "Signed Out"
        case .signOutBackendUnreachable: "Can’t Reach Purrdr"
        }
    }

    var message: String {
        switch self {
        case .failed(let message):
            message
        case .subscriptionConflict:
            String(localized: "Both members have an active subscription, and a member can only have one. Cancel one of them first, then try again. Nothing was changed.")
        case .subscriptionInUse:
            String(localized: "That subscription already belongs to another member.")
        case .methodAlreadyLinked:
            String(localized: "This member already has that kind of sign-in method. Unlink it first.")
        case .merged:
            String(localized: "Both sign-in methods now sign in to the same member. Hosts and notification devices were combined.")
        case .autoLinked:
            String(localized: "This account uses the same verified email as an existing member, so it now signs in to that member.")
        case .deleted:
            String(localized: "Your member account and its data were deleted. If you subscribed to Purrdr Plus, cancel it in Settings › Apple Account › Subscriptions so you aren’t charged again.")
        case .signedOut:
            String(localized: "Your sign-in expired. Sign in again to continue.")
        case .signOutBackendUnreachable:
            String(localized: "Couldn’t notify Purrdr, so this device’s notification pairing may still be active. You can sign out anyway.")
        }
    }
}


// MARK: - 沒登入流程的外框(標題、左上動作、步驟)

extension AccountEntryFlow {
    /// 目前要顯示的沒登入流程畫面;`nil` 表示顯示帳號頁。
    ///
    /// 已登入時,剛登入完成、還在換頁的那一刻(登入頁、建立會員頁)照舊顯示,免得閃出帳號頁;
    /// 沒有 Purrdr Plus 的 model 時加入流程到建立會員為止。
    func shownScreen(phase: MemberModel.Phase, hasPlus: Bool) -> Screen? {
        switch (phase, screen) {
        case (.signedOut, .account): .choose
        case (.signedOut, let screen): screen
        case (.signedIn, .signIn): .signIn
        case (.signedIn, .join): hasPlus || join.step == .createMember ? .join : nil
        default: nil
        }
    }

    func navigationTitle(phase: MemberModel.Phase, hasPlus: Bool) -> LocalizedStringKey {
        guard shownScreen(phase: phase, hasPlus: hasPlus) != nil else { return "Account" }
        switch title {
        case .account: return "Account"
        case .signIn: return "Sign In"
        case .join: return "Join as a Member"
        }
    }
}

/// 沒登入流程的 toolbar:左上圓形「返回」或「關閉」,右上加入流程的「n / 4」。
struct AccountEntryToolbar: ToolbarContent {
    @Binding var entry: AccountEntryFlow
    let onClose: () -> Void

    var body: some ToolbarContent {
        switch entry.leadingAction {
        case .back:
            ToolbarItem(placement: .cancellationAction) {
                Button { entry.back() } label: { Image(systemName: "chevron.backward") }
                    .accessibilityLabel(Text("Back"))
                    .accessibilityIdentifier("member.entry.back")
            }
        case .close:
            // 所有 modal 的關閉都在左上角「X」(#613)。
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark", action: onClose)
                    .accessibilityLabel(entry.screen == .join ? Text("Close. Continue in Account Later") : Text("Close"))
                    .accessibilityIdentifier("member.signIn.cancel")
            }
        }
        if let indicator = entry.stepIndicator {
            ToolbarItem(placement: .confirmationAction) {
                Text(verbatim: "\(indicator.current) / \(indicator.total)")
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                    .accessibilityLabel(Text("Step \(indicator.current) of \(indicator.total)"))
                    .accessibilityIdentifier("member.entry.step")
            }
        }
    }
}

/// 刪除會員前先處理訂閱(#412、設計稿第 28 組、App Store 審查準則 5.1.1(v)):
/// 說明刪除不會取消訂閱、商店會繼續收費。App Store 訂閱提供系統的「管理訂閱」;Google Play 只給文字指引、不放連結。
struct DeletionSubscriptionView: View {
    let notice: DeletionSubscriptionNotice
    let manage: () -> Void
    let proceed: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Take Care of Your Subscription First")
                        .font(.title3.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("member.deleteSubscription.message")
                }
                .listRowBackground(Color.clear)
            }
            if notice == .appStore {
                Section {
                    Button("Manage Subscription", action: manage)
                        .accessibilityIdentifier("member.deleteSubscription.manage")
                }
            }
            Section {
                Button("Continue Deleting Member", role: .destructive, action: proceed)
                    .accessibilityIdentifier("member.deleteSubscription.continue")
            }
        }
        .appGroupedList()
        .navigationTitle("Delete Member")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("member.deleteSubscription")
    }

    private var message: String {
        switch notice {
        case .appStore:
            String(localized: "You have Purrdr Plus through the App Store. Deleting your member account doesn’t cancel it, and Apple will keep charging you. Cancel the subscription first, then continue.")
        case .googlePlay:
            String(localized: "You have Purrdr Plus through Google Play. Deleting your member account doesn’t cancel it, and Google will keep charging you. Go to Google Play to cancel it first, then continue.")
        }
    }
}
