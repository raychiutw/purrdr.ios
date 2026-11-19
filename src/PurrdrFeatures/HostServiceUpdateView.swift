import SwiftUI

/// 主機服務的更新說明(#198):0.5.0 起執行 `purrdr-host-service update`,更舊的版本重跑一次一行安裝指令
/// (就地更新、保留已配對的裝置，之後自動更新)。指令等寬、可選取拷貝，有拷貝按鈕;可以不再提示這個版本。
struct HostServiceUpdateView: View {
    let hostName: String
    let version: String
    let commands: HostServiceUpdateCommands
    let dismissUpdate: () -> Void

    var body: some View {
        List {
            Section {
                explanation
                    .accessibilityIdentifier("hostServiceUpdate.explanation")
            }
            command(String(localized: "macOS and Linux"), commands.posix, identifier: "posix")
            command(String(localized: "Windows (PowerShell)"), commands.windows, identifier: "windows")
            Section {
                Link(destination: PurrdrLinks.hostServiceGuide) {
                    Label("Host Service Guide", systemImage: "book")
                }
                .accessibilityIdentifier("hostServiceUpdate.guide")
                Button("Don’t Remind Me About This Version", action: dismissUpdate)
                    .accessibilityIdentifier("hostServiceUpdate.dismiss")
            }
        }
        .navigationTitle("Update Host Service")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var explanation: Text {
        if commands.canUpdateItself {
            Text("Purrdr host service \(version) is available for \(hostName). The host service updates itself automatically; to update now, run this on the host. Paired devices stay paired.")
        } else {
            Text("Purrdr host service \(version) is available for \(hostName). This host runs \(commands.installedVersion), which can’t update itself: run the install command on the host once. From 0.5.0 on, the host service updates itself, or you can run purrdr-host-service update. Paired devices stay paired.")
        }
    }

    private func command(_ title: String, _ command: String, identifier: String) -> some View {
        Section {
            Text(verbatim: command)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("hostServiceUpdate.command.\(identifier)")
            Button("Copy Command", systemImage: "document.on.document") { Clipboard.copy(command) }
                .accessibilityIdentifier("hostServiceUpdate.copy.\(identifier)")
        } header: {
            Text(title)
                .foregroundStyle(.secondaryText)
        }
    }
}
