import AuthenticationServices
import PurrdrCore
import SwiftUI

/// 會員畫面：未登入時是登入頁，登入後是登入方式與刪除會員(HIG 檢核清單 20.10、20.11)。
///
/// 只有訂閱功能需要會員;聊天與終端機不需要登入，所以這個畫面只從選單進來，不會擋在任何功能前面。
public struct MemberView: View {
    @Bindable var model: MemberModel
    /// 已登入時顯示 Purrdr Plus 的狀態與入口;`nil` 時不顯示(例如從付費牆開來登入)。
    let plus: SubscriptionModel?
    @Environment(\.dismiss) private var dismiss

    public init(model: MemberModel, plus: SubscriptionModel? = nil) {
        self.model = model
        self.plus = plus
    }

    public var body: some View {
        NavigationStack {
            MemberContent(model: model, plus: plus)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("member.done")
                    }
                }
        }
    }
}

/// 會員畫面的內容(不含 NavigationStack 與「完成」):設定頁在自己的 sheet 裡 push 這個畫面(#32)。
public struct MemberContent: View {
    @Bindable var model: MemberModel
    /// 已登入時顯示 Purrdr Plus 的狀態與入口;`nil` 時不顯示。
    let plus: SubscriptionModel?

    public init(model: MemberModel, plus: SubscriptionModel? = nil) {
        self.model = model
        self.plus = plus
    }

    public var body: some View {
        content
            .navigationTitle("Purrdr Member")
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
        switch model.phase {
        case .unknown:
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
        case .signedOut:
            SignInView(model: model)
        case .signedIn(let member):
            AccountView(model: model, member: member, plus: plus)
        }
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }
}

// MARK: - 登入頁

/// 登入頁：說明成為會員的好處，下方固定兩個登入按鈕(不需捲動就看得到)。
struct SignInView: View {
    let model: MemberModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Sign in to use Purrdr Plus")
                    .font(.title2.bold())
                Text("A member account is only needed for Purrdr Plus: notifications when an agent needs you, and syncing your hosts between devices.")
                Text("Chat and terminal never need an account, and your conversations never pass through our servers.")
                    .foregroundStyle(.secondary)
            }
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
        .buttonStyle(.plain)
        .accessibilityIdentifier("member.signIn.google")
    }
}

// MARK: - 會員(已登入)

/// 已登入：目前的登入方式、連結／解除、登出、刪除會員。
struct AccountView: View {
    let model: MemberModel
    let member: Member
    let plus: SubscriptionModel?
    @State private var confirmingDeletion = false

    var body: some View {
        List {
            if let plus {
                Section {
                    NavigationLink {
                        PlusView(model: plus, member: model)
                    } label: {
                        LabeledContent("Purrdr Plus") {
                            Text(plus.statusText)
                        }
                    }
                    .accessibilityIdentifier("member.plus")
                } footer: {
                    if plus.needsRenewal {
                        Text("Your subscription has ended. Notifications and host sync are paused until you subscribe again.")
                    }
                }
                .task { await plus.refresh() }
            }

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
            } header: {
                Text("Sign-In Methods")
            } footer: {
                Text("Link another sign-in method to reach the same member from either. Keep at least one.")
            }

            let unlinked = SignInMethod.allCases.filter { member.identity($0) == nil }
            if !unlinked.isEmpty {
                Section("Link Another Method") {
                    SignInButtons(model: model, linking: true, methods: unlinked)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
            }

            Section {
                Button("Sign Out") { Task { await model.signOut() } }
            }

            Section {
                Button("Delete Member…", role: .destructive) { confirmingDeletion = true }
                    .accessibilityIdentifier("member.delete")
            } footer: {
                Text("Deleting your member account removes it and its data from Purrdr right away. Subscriptions billed by Apple continue until you cancel them in Settings.")
            }
        }
        .disabled(model.isWorking)
        .confirmationDialog("Delete your member account?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Member", role: .destructive) { Task { await model.deleteMember() } }
        } message: {
            Text("Your member account, push pairings, and synced hosts will be deleted. This can’t be undone. A Purrdr Plus subscription isn’t canceled automatically — cancel it in Settings › Apple Account › Subscriptions.")
        }
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
