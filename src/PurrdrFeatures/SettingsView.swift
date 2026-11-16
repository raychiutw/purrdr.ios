import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 設定 sheet(#32;行為規格 F15 的子集)。標準 grouped list,不提供 app 內深淺色設定(跟隨系統)。
///
/// 會員從這裡在同一個 sheet 內 push 進去(HIG 20.3:多步驟在同一個 sheet 內 push,不疊第二個 sheet)。
public struct SettingsView: View {
    @Bindable var model: SettingsModel
    let member: MemberModel
    /// Purrdr Plus(#28):會員畫面已登入時顯示狀態與入口;`nil` 時不顯示。
    let plus: SubscriptionModel?
    /// 選取中主機的推播開關(#29);`nil` 或沒有推播服務時不顯示「通知」區。
    let push: PushModel?
    /// 主機同步(#30);`nil` 時不顯示。
    let hostSync: HostSyncModel?
    /// 選取中主機的主機主題與「You should know」寫回(#23);`nil` 時不顯示。
    let hostTheme: HostThemeModel?
    let youShouldKnow: YouShouldKnowModel?
    /// 推播需要 Purrdr Plus 時開付費牆。
    let openPlus: () -> Void
    /// 選取中主機的 Codex 啟動器;`nil` 時不顯示。
    let codexLauncher: CodexLauncherModel?
    /// 需要處理的 workspace 數(「完成」旁的數字，行為規格 F2.8)。
    let attention: () -> Int
    /// 再看一次歡迎頁(#34;HIG Onboarding:跳過後在設定找得到)。
    let openWelcome: () -> Void
    let done: () -> Void

    public init(
        model: SettingsModel, member: MemberModel, plus: SubscriptionModel? = nil, push: PushModel? = nil,
        hostSync: HostSyncModel? = nil, hostTheme: HostThemeModel? = nil, youShouldKnow: YouShouldKnowModel? = nil,
        openPlus: @escaping () -> Void = {}, codexLauncher: CodexLauncherModel? = nil,
        attention: @escaping () -> Int = { 0 }, openWelcome: @escaping () -> Void = {}, done: @escaping () -> Void
    ) {
        self.attention = attention
        self.openWelcome = openWelcome
        self.model = model
        self.member = member
        self.plus = plus
        self.push = push
        self.hostSync = hostSync
        self.hostTheme = hostTheme
        self.youShouldKnow = youShouldKnow
        self.openPlus = openPlus
        self.codexLauncher = codexLauncher
        self.done = done
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        MemberContent(model: member, plus: plus)
                    } label: {
                        Label("Purrdr Member", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("settings.member")
                }

                if let push, push.isAvailable {
                    PushSettingsSection(model: push, openPlus: openPlus)
                }

                if let hostSync {
                    HostSyncSection(model: hostSync, plus: plus, member: member)
                }

                if let hostTheme {
                    HostThemeSettingsSection(model: hostTheme)
                }
                if let youShouldKnow {
                    YouShouldKnowSettingsSection(model: youShouldKnow)
                }

                Section {
                    Toggle("Return Key Sends", isOn: $model.returnSends)
                        .accessibilityIdentifier("settings.returnSends")
                } header: {
                    Text("Hardware Keyboard")
                        .foregroundStyle(.secondaryText)
                } footer: {
                    Text("When off, Return adds a new line. Command-Return always sends, and Shift-Return always adds a new line.")
                        .foregroundStyle(.secondaryText)
                }

                if let codexLauncher {
                    CodexLauncherSection(model: codexLauncher)
                }

                Section {
                    Toggle("Haptics", isOn: $model.hapticsEnabled)
                        .accessibilityIdentifier("settings.haptics")
                } footer: {
                    Text("Feel a tap when you answer an agent, and whether the answer arrived.")
                        .foregroundStyle(.secondaryText)
                }

                Section {
                    Button("Show Welcome", systemImage: "hand.wave") { openWelcome() }
                        .accessibilityIdentifier("settings.welcome")
                    Button("Rate Purrdr", systemImage: "star") { model.rateApp() }
                        .accessibilityIdentifier("settings.rate")
                    Button("Support", systemImage: "questionmark.circle") { model.openSupport() }
                        .accessibilityIdentifier("settings.support")
                    Button(
                        model.copiedDiagnostics ? "Copied" : "Copy Diagnostics",
                        systemImage: model.copiedDiagnostics ? "checkmark" : "document.on.document"
                    ) { model.copyDiagnostics() }
                        .accessibilityIdentifier("settings.copyDiagnostics")
                } header: {
                    Text("Support")
                        .foregroundStyle(.secondaryText)
                } footer: {
                    Text("Diagnostics include the app version, iOS version, number of hosts, and herdr version — never host names, addresses, user names, or conversations.")
                        .foregroundStyle(.secondaryText)
                }

                Section {
                    LabeledContent("Version", value: model.appVersionText)
                        .accessibilityIdentifier("settings.version")
                    LabeledContent("herdr on Host") { herdrVersionText }
                        .accessibilityIdentifier("settings.herdrVersion")
                    Button("Privacy Policy", systemImage: "hand.raised") { model.openPrivacyPolicy() }
                        .accessibilityIdentifier("settings.privacy")
                } header: {
                    Text("About")
                        .foregroundStyle(.secondaryText)
                }
            }
            .accessibilityIdentifier("sheet.settings")
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 6) {
                        AttentionBadge(count: attention())
                        Button("Done", action: done)
                            .accessibilityIdentifier("sheet.done")
                    }
                }
            }
        }
        .task { await model.load() }
    }

    private var herdrVersionText: Text {
        switch model.herdrVersion {
        case .noHost: Text("No Host")
        case .loading: Text("Checking…")
        case .reported(let version): Text(verbatim: version)
        case .unavailable: Text("Not Available")
        }
    }
}

/// 平台服務的系統實作。
@MainActor
public final class SystemPlatformServices: PlatformServices {
    public init() {}

    public func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    public func copy(_ text: String) {
        Clipboard.copy(text)
    }
}
