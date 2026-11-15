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
    let done: () -> Void

    public init(model: SettingsModel, member: MemberModel, done: @escaping () -> Void) {
        self.model = model
        self.member = member
        self.done = done
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        MemberContent(model: member)
                    } label: {
                        Label("Purrdr Member", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("settings.member")
                }

                Section {
                    Toggle("Return to Send", isOn: $model.returnSends)
                        .accessibilityIdentifier("settings.returnSends")
                } header: {
                    Text("Chat")
                } footer: {
                    Text("With a hardware keyboard, Return sends your message. Turn this off to make Return start a new line; Command-Return always sends.")
                }

                Section {
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
                } footer: {
                    Text("Diagnostics include the app version, iOS version, number of hosts, and herdr version — never host names, addresses, user names, or conversations.")
                }

                Section("About") {
                    LabeledContent("Version", value: model.appVersionText)
                        .accessibilityIdentifier("settings.version")
                    LabeledContent("herdr on Host") { herdrVersionText }
                        .accessibilityIdentifier("settings.herdrVersion")
                    Button("Privacy Policy", systemImage: "hand.raised") { model.openPrivacyPolicy() }
                        .accessibilityIdentifier("settings.privacy")
                }
            }
            .accessibilityIdentifier("sheet.settings")
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                        .accessibilityIdentifier("sheet.done")
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
