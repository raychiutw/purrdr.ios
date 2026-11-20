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
    /// 主機同步(步驟四)。
    let hostSync: HostSyncModel?
    @Environment(\.dismiss) private var dismiss

    public init(model: MemberModel, plus: SubscriptionModel? = nil, pushes: [HostPush] = [], hostSync: HostSyncModel? = nil) {
        self.model = model
        self.plus = plus
        self.pushes = pushes
        self.hostSync = hostSync
    }

    public var body: some View {
        NavigationStack {
            MemberContent(model: model, plus: plus, pushes: pushes, hostSync: hostSync)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("member.done")
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
    let hostSync: HostSyncModel?

    public init(model: MemberModel, plus: SubscriptionModel? = nil, pushes: [HostPush] = [], hostSync: HostSyncModel? = nil) {
        self.model = model
        self.plus = plus
        self.pushes = pushes
        self.hostSync = hostSync
    }

    public var body: some View {
        content
            .navigationTitle("Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        .task {
            if model.phase == .unknown { await model.restore() }
        }
        .alert(model.notice?.title ?? "", isPresented: noticePresented, presenting: model.notice) { notice in
            if notice == .deleted {
                Link("Manage Subscriptions", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.phase == .unknown {
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
            AccountView(model: model, plus: plus, pushes: pushes, hostSync: hostSync)
        }
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }
}

/// 只有登入的 sheet(付費牆的「登入以訂閱」):登入完成就自動關閉。
struct SignInSheet: View {
    let model: MemberModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SignInView(model: model)
                .navigationTitle("Join as a Member")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("member.signIn.cancel")
                    }
                }
        }
        .onChange(of: model.phase) { _, phase in
            if case .signedIn = phase { dismiss() }
        }
    }
}

// MARK: - 登入頁

/// 登入頁：只有標題(#236),下方固定兩個登入按鈕(不需捲動就看得到)。
struct SignInView: View {
    let model: MemberModel

    var body: some View {
        ScrollView {
            Text("Sign in to use Purrdr Plus")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .safeAreaInset(edge: .bottom) {
            SignInButtons(model: model, linking: false, methods: SignInMethod.allCases)
                .padding()
                .background(.bar)
        }
    }
}

/// Sign in with Apple 與 Google 按鈕：同寬、同高、同圓角(Apple 按鈕不得小於其他登入按鈕)。
struct SignInButtons: View {
    let model: MemberModel
    let linking: Bool
    let methods: [SignInMethod]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    /// 跟著字級放大，但最高 88 pt,免得 AX 字級時把說明擠出畫面。
    @ScaledMetric(relativeTo: .body) private var scaledHeight: CGFloat = 50
    private var height: CGFloat { min(max(scaledHeight, 50), 88) }
    static let cornerRadius: CGFloat = 12

    var body: some View {
        VStack(spacing: 12) {
            ForEach(methods, id: \.self) { method in
                switch method {
                case .apple: appleButton
                case .google: googleButton
                }
            }
        }
        .disabled(model.isWorking)
    }

    private var appleButton: some View {
        SignInWithAppleButton(linking ? .continue : .signIn) { request in
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
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
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
            Text(linking ? "Continue with Google" : "Sign in with Google")
                .font(.body.weight(.medium))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .foregroundStyle(.primary)
                .background(.background, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(.secondary, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        }
        .buttonStyle(.pressableCard(cornerRadius: Self.cornerRadius))
        .accessibilityIdentifier("member.signIn.google")
    }
}

// MARK: - 帳號頁

/// 帳號頁：頭像、步驟卡(完成後收成一列)、每台主機的通知、主機同步、登入方式、登出、刪除會員。
struct AccountView: View {
    let model: MemberModel
    let plus: SubscriptionModel?
    let pushes: [HostPush]
    let hostSync: HostSyncModel?
    @State private var confirmingDeletion = false
    @State private var signingIn = false
    @State private var showingPlus = false
    @State private var offeringFeatureSetup = false
    /// 每次加一：步驟卡「選擇主機」捲到「通知」區塊。
    @State private var notificationsScrollRequest = 0

    private var signedInMember: Member? {
        if case .signedIn(let member) = model.phase { return member }
        return nil
    }

    private var notifyingHostNames: [String] { pushes.notifyingHostNames }

    private var progress: PlusSetupProgress? {
        plus.map { PlusSetupProgress(member: model, plus: $0, isNotificationsOn: !notifyingHostNames.isEmpty, hostSync: hostSync) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            list
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

            if let plus, let progress {
                plusSection(plus: plus, progress: progress)
                if progress.isPlusActive {
                    // 四步完成、步驟卡收合後，通知與主機同步仍可隨時開關(spec #261 原型 A)。
                    HostPushSection(pushes: pushes) { showingPlus = true }
                    if let hostSync, progress.state(of: .syncHosts) == .done {
                        HostSyncSection(model: hostSync, plus: plus, member: model)
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
                    Button("Delete Member…", role: .destructive) { confirmingDeletion = true }
                        .accessibilityIdentifier("member.delete")
                } footer: {
                    Text("Deleting your member account removes it and its data from Purrdr right away. Subscriptions billed by Apple continue until you cancel them in Settings.")
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("sheet.account")
        .disabled(model.isWorking)
        .navigationDestination(isPresented: $signingIn) {
            SignInView(model: model)
                .navigationTitle("Join as a Member")
        }
        .navigationDestination(isPresented: $showingPlus) {
            if let plus {
                PlusView(model: plus, member: model)
            }
        }
        .onChange(of: signedInMember?.id) { _, id in
            if id != nil { signingIn = false }
        }
        .onChange(of: progress) { previous, current in
            // 只有從這裡進付費牆開通才問;開帳號頁時讀回訂閱不算剛開通。
            guard showingPlus, let previous, let current, current.offersFeatureSetup(after: previous) else { return }
            showingPlus = false
            offeringFeatureSetup = true
        }
        .task(id: signedInMember?.id) { await plus?.refresh() }
        .hostPushConfirmation(pushes)
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
    private func plusSection(plus: SubscriptionModel, progress: PlusSetupProgress) -> some View {
        Section {
            if progress.isComplete {
                NavigationLink {
                    PlusView(model: plus, member: model)
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
                        PlusView(model: plus, member: model)
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

    private func perform(_ step: PlusSetupProgress.Step) {
        switch step {
        case .joinMember: signingIn = true
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

/// 帳號頁頂端的頭像與名稱;未加入會員顯示「?」。
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

/// 帳號頭像：主色填色(`prominentFill`)圓底上的頭像字;沒有字時用人像符號，未加入會員(`nil`)用「?」。帳號鈕與帳號頁共用。
struct AccountAvatar: View {
    let member: Member?

    var body: some View {
        ZStack {
            Circle().fill(.prominentFill)
            Group {
                if let member {
                    if let initial = member.avatarInitial {
                        Text(verbatim: initial)
                    } else {
                        Image(systemName: "person.fill")
                    }
                } else {
                    // 圖示而非文字：AX 字級時帳號鈕收進溢出選單，選單項目會把畫面上的「?」當名稱。
                    Image(systemName: "questionmark")
                }
            }
            .fontWeight(.semibold)
            .foregroundStyle(.onProminentFill)
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
            } footer: {
                Text("Link another sign-in method to reach the same member from either. Keep at least one.")
                    .foregroundStyle(.secondaryText)
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
        }
    }
}
