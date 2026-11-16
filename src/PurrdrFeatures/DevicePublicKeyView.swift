import PurrdrCore
import SwiftUI

/// 這支裝置的公鑰(HIG 檢核 20.3):等寬、可選取拷貝，有拷貝與分享按鈕，並附各作業系統把它加到主機的指令。
struct DevicePublicKeyView: View {
    let publicKey: SSHPublicKey
    /// 要登入的使用者(說明「以誰的身分執行」)。
    let username: String

    var body: some View {
        List {
            Section {
                Text(verbatim: publicKey.openSSH)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("deviceKey.publicKey")
                Button("Copy Public Key", systemImage: "document.on.document") { Clipboard.copy(publicKey.openSSH) }
                    .accessibilityIdentifier("deviceKey.copy")
                ShareLink(item: publicKey.openSSH) {
                    Label("Share Public Key", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("deviceKey.share")
            } header: {
                Text("Public Key")
                    .foregroundStyle(.secondaryText)
            } footer: {
                Text("The private key stays in this device’s Secure Enclave and never leaves it. Add this public key to each host you sign in to.")
                    .foregroundStyle(.secondaryText)
            }

            Section {
                Text(verbatim: publicKey.fingerprint.description)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("deviceKey.fingerprint")
            } header: {
                Text("Fingerprint")
                    .foregroundStyle(.secondaryText)
            }

            ForEach(AuthorizedKeyCommand.Platform.allCases, id: \.self) { platform in
                let command = AuthorizedKeyCommand.command(adding: publicKey, on: platform)
                Section {
                    Text(verbatim: command)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("deviceKey.command.\(platform.identifier)")
                    Button("Copy Command", systemImage: "document.on.document") { Clipboard.copy(command) }
                        .accessibilityIdentifier("deviceKey.copyCommand.\(platform.identifier)")
                } header: {
                    Text(platform.title)
                        .foregroundStyle(.secondaryText)
                } footer: {
                    Text(platform.footer(username: username))
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .navigationTitle("This Device’s Key")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

extension AuthorizedKeyCommand.Platform {
    var identifier: String {
        switch self {
        case .macOSAndLinux: "macOSAndLinux"
        case .windows: "windows"
        case .windowsAdministrator: "windowsAdministrator"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .macOSAndLinux: "macOS and Linux"
        case .windows: "Windows"
        case .windowsAdministrator: "Windows Administrator Account"
        }
    }

    func footer(username: String) -> String {
        let user = username.isEmpty ? String(localized: "the user Purrdr signs in as") : username
        return switch self {
        case .macOSAndLinux:
            String(localized: "Run this in Terminal on the host, signed in as \(user). On a Mac, also turn on Remote Login in System Settings › General › Sharing.")
        case .windows:
            String(localized: "Run this in PowerShell on the host, signed in as \(user).")
        case .windowsAdministrator:
            String(localized: "If \(user) is an administrator, Windows OpenSSH reads this file instead. Run this in PowerShell as administrator.")
        }
    }
}
