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
    /// 沒登入時的流程(#408):選擇、登入、加入。
    @State private var entry = AccountEntryFlow()
    @Environment(\.dismiss) private var dismiss

    public init(
        model: MemberModel, plus: SubscriptionModel? = nil, pushes: [HostPush] = [], pushDevices: PushDevicesModel? = nil,
        hostSync: HostSyncModel? = nil, hosts: HostsModel? = nil
    ) {
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
                model: model, plus: plus, pushes: pushes, pushDevices: pushDevices, hostSync: hostSync, hosts: hosts, entry: $entry
            )
            .toolbar {
                if entry.shownScreen(phase: model.phase, hasPlus: plus != nil) != nil {
                    AccountEntryToolbar(entry: $entry, onClose: { dismiss() })
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("member.done")
                    }
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
    @Binding var entry: AccountEntryFlow

    public init(
        model: MemberModel, plus: SubscriptionModel? = nil, pushes: [HostPush] = [], pushDevices: PushDevicesModel? = nil,
        hostSync: HostSyncModel? = nil, hosts: HostsModel? = nil, entry: Binding<AccountEntryFlow>
    ) {
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
                AccountEntryPages(model: model, entry: $entry)
            }
        } else if model.phase == .unknown {
            if model.isWorking {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("Can’t Reach Purrdr", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Your sign-in is kept on this device. Try again when you’re online.")
                } actions: {
                    Button("Try Again") { Task { await model.restore() } }
                }
            }
        } else {
            AccountView(model: model, plus: plus, pushes: pushes, pushDevices: pushDevices, hostSync: hostSync, hosts: hosts)
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
            Task { await model.signIn(with: credential) }
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
            request.nonce = model.beginAppleAuthorization(linking: linking)
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
                    await model.signInWithGoogle(browser: browser)
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

/// 帳號頁：頭像、步驟卡(完成後收成一列)、每台主機的通知、通知裝置、主機同步、登入方式、登出、刪除會員。
struct AccountView: View {
    let model: MemberModel
    let plus: SubscriptionModel?
    let pushes: [HostPush]
    let pushDevices: PushDevicesModel?
    let hostSync: HostSyncModel?
    let hosts: HostsModel?
    @State private var confirmingDeletion = false
    /// 從通知列開配對的主機(#295)。
    @State private var pairingHost: UUID?
    @State private var showingPlus = false
    @State private var offeringFeatureSetup = false
    /// 每次加一：步驟卡「選擇主機」捲到「通知」區塊。
    @State private var notificationsScrollRequest = 0
    /// Purrdr Plus 頁點功能列後捲到帳號頁對應的區塊(#323)。
    @State private var featureScrollRequest: PlusFeature?

    private var signedInMember: Member? {
        if case .signedIn(let member) = model.phase { return member }
        return nil
    }

    private var notifyingHostNames: [String] { pushes.notifyingHostNames }

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
                    withAnimation { proxy.scrollTo(feature, anchor: .top) }
                }
                .onChange(of: notificationsScrollRequest) {
                    guard let first = pushes.first else { return }
                    withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                }
        }
    }

    private var list: some View {
        List {
            Section {
                AccountHeader(member: signedInMember)
            }
            .listRowBackground(Color.clear)

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

            if let plus, let progress {
                plusSection(plus: plus, progress: progress)
                if progress.isPlusActive {
                    // 四步完成、步驟卡收合後，通知與主機同步仍可隨時開關(spec #261 原型 A)。
                    HostPushSection(pushes: pushes, openPlus: { showingPlus = true }, pair: { pairingHost = $0 })
                        .id(PlusFeature.notifications)
                }
                if signedInMember != nil, let pushDevices {
                    // 訂閱到期也顯示：仍可遠端關閉遺失的裝置。
                    PushDevicesSection(model: pushDevices, canRename: progress.isPlusActive)
                        .id(PlusFeature.devices)
                }
                if progress.isPlusActive {
                    if let hostSync, progress.state(of: .syncHosts) == .done {
                        HostSyncSection(model: hostSync, plus: plus, member: model)
                            .id(PlusFeature.hostSync)
                    }
                }
            }

            if let member = signedInMember {
                Section {
                    NavigationLink {
                        SignInMethodsView(model: model, member: member)
                    } label: {
                        Text("Sign-In Methods")
                    }
                    .accessibilityIdentifier("member.signInMethods")
                    Button("Sign Out") { Task { await model.signOut() } }
                    Button("Delete Member", role: .destructive) { confirmingDeletion = true }
                        .accessibilityIdentifier("member.delete")
                }
            }
        }
        .appGroupedList()
        .accessibilityIdentifier("sheet.account")
        .disabled(model.isWorking)
        .navigationDestination(isPresented: $showingPlus) {
            if let plus {
                PlusView(model: plus, member: model, features: plusFeatures)
            }
        }
        .navigationDestination(item: $pairingHost) { id in
            if let hosts, let host = hosts.hosts.first(where: { $0.id == id }) {
                // 與主機頁點「還沒配對」的主機開的是同一個引導(直接到配對那一步);存好回到帳號頁，那台主機的開關就能用。
                AddHostGuideScreen(
                    make: { (try? hosts.makePairingGuide(for: host)) ?? hosts.makeAddHostGuide() },
                    onSaved: { _ in pairingHost = nil },
                    onCancel: { pairingHost = nil },
                    onAdded: { hosts.didSave($0) },
                    hostPush: { id in hosts.hostPushes.first { $0.host == .host(id) } })
            }
        }
        .onChange(of: progress) { previous, current in
            // 只有從這裡進付費牆開通才問;開帳號頁時讀回訂閱不算剛開通。
            guard showingPlus, let previous, let current, current.offersFeatureSetup(after: previous) else { return }
            showingPlus = false
            offeringFeatureSetup = true
        }
        .task(id: signedInMember?.id) { await plus?.refresh() }
        .hostPushConfirmation(pushes)
        .pushDevicesDialogs(signedInMember != nil ? pushDevices : nil, notifyingHostNames: notifyingHostNames)
        .alert("Purrdr Plus Is On", isPresented: $offeringFeatureSetup) {
            Button("Later", role: .cancel) {}
            Button("Turn On All") { turnOnAll() }
                .accessibilityIdentifier("account.turnOnAll")
        } message: {
            Text("Turn on notifications and host sync now? You can change them later.")
        }
        .confirmationDialog("Delete your member account?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Member", role: .destructive) { Task { await model.deleteMember() } }
        } message: {
            Text("Your member account, push pairings, and synced hosts will be deleted. This can’t be undone. A Purrdr Plus subscription isn’t canceled automatically — cancel it in Settings › Apple Account › Subscriptions.")
        }
    }

    @ViewBuilder
    private func plusSection(plus: SubscriptionModel, progress: AccountSetupProgress) -> some View {
        Section {
            if progress.isComplete {
                NavigationLink {
                    PlusView(model: plus, member: model, features: plusFeatures)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Purrdr Plus · Active")
                        Text(plus.statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityIdentifier("member.plus")
            } else {
                PlusSetupCard(progress: progress, notifyingHostNames: notifyingHostNames, isWorking: isStepWorking) { perform($0) }
                if progress.isPlusActive {
                    NavigationLink {
                        PlusView(model: plus, member: model, features: plusFeatures)
                    } label: {
                        LabeledContent("Purrdr Plus") { Text(plus.statusText) }
                    }
                    .accessibilityIdentifier("member.plus")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let hint = progress.lockedFeatureHint {
                    Text(hint.text)
                        .accessibilityIdentifier("account.lockedHint")
                }
                if plus.needsRenewal {
                    Text("Your subscription has ended. Notifications and host sync are paused until you subscribe again.")
                }
                Text("Chat and terminal don’t need a member account or subscription.")
            }
            .foregroundStyle(.secondaryText)
        }
    }

    private var isStepWorking: Bool {
        pushes.contains { push in
            switch push.model.state {
            case .checking, .turningOn, .confirming: true
            case .off, .on, .turningOff: false
            }
        }
    }

    private func perform(_ step: AccountSetupProgress.Step) {
        switch step {
        case .joinMember: break  // 已登入才會看到帳號頁,這一步已完成
        case .activatePlus: showingPlus = true
        case .turnOnNotifications: notificationsScrollRequest += 1
        case .syncHosts: Task { await hostSync?.setEnabled(true) }
        }
    }

    /// 開通後的「全部開啟」:同步直接開;只有一台能開通知的主機時直接開(仍經安裝確認),否則捲到「通知」讓使用者挑。
    private func turnOnAll() {
        Task { await hostSync?.setEnabled(true) }
        let supported = pushes.filter { $0.support == .supported }
        if supported.count == 1, let only = supported.first {
            Task { await only.model.requestOn() }
        } else {
            notificationsScrollRequest += 1
        }
    }
}

/// 帳號頁頂端的頭像與名稱;未加入會員顯示人頭圖。
private struct AccountHeader: View {
    let member: Member?

    var body: some View {
        VStack(spacing: 8) {
            AccountAvatar(member: member)
                .font(.largeTitle)
                .frame(width: 72, height: 72)
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
            .font(.title3.bold())
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
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

/// 登入方式：目前的登入方式、解除連結、連結另一種。
struct SignInMethodsView: View {
    let model: MemberModel
    let member: Member

    var body: some View {
        List {
            Section {
                ForEach(member.identities, id: \.method) { identity in
                    LabeledContent {
                        if member.identities.count > 1 {
                            Button("Unlink", role: .destructive) { Task { await model.unlink(identity.method) } }
                                .accessibilityLabel(Text("Unlink \(identity.method.displayName)"))
                        }
                    } label: {
                        Text("Using \(identity.method.displayName)")
                        if let email = identity.email {
                            Text(email)
                        }
                    }
                    .accessibilityIdentifier("member.identity.\(identity.method.rawValue)")
                }
            }

            let unlinked = SignInMethod.allCases.filter { member.identity($0) == nil }
            if !unlinked.isEmpty {
                Section {
                    SignInButtons(model: model, linking: true, methods: unlinked)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    Text("Link Another Method")
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
    }
}

extension SignInMethod {
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
        case .identityInUse: "Already Used by Another Member"
        case .methodAlreadyLinked: "Already Linked"
        case .merged: "Members Combined"
        case .deleted: "Member Deleted"
        case .signedOut: "Signed Out"
        case .signOutBackendUnreachable: "Can’t Reach Purrdr"
        }
    }

    var message: String {
        switch self {
        case .failed(let message):
            message
        case .identityInUse:
            String(localized: "That sign-in method belongs to another member with a subscription or synced hosts. Sign in with it, delete that member, then link it here.")
        case .methodAlreadyLinked:
            String(localized: "This member already has that kind of sign-in method. Unlink it first.")
        case .merged:
            String(localized: "That sign-in method had an empty member of its own. It was combined into this one.")
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
        ToolbarItem(placement: .cancellationAction) {
            switch entry.leadingAction {
            case .back:
                Button { entry.back() } label: { Image(systemName: "chevron.backward") }
                    .accessibilityLabel(Text("Back"))
                    .accessibilityIdentifier("member.entry.back")
            case .close:
                Button(action: onClose) { Image(systemName: "xmark") }
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
