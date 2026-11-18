import SwiftUI

/// 主機服務的更新說明(#198):在主機上再跑一次一行安裝指令(就地更新、保留已配對的裝置)。
/// 指令等寬、可選取拷貝，有拷貝按鈕;可以不再提示這個版本。
struct HostServiceUpdateView: View {
    let hostName: String
    let version: String
    let dismissUpdate: () -> Void

    var body: some View {
        List {
            Section {
                Text("Purrdr host service \(version) is available for \(hostName). Run this on the host to update it. Paired devices stay paired.")
                    .accessibilityIdentifier("hostServiceUpdate.explanation")
            }
            command(String(localized: "macOS and Linux"), HostServiceUpdates.posixInstallCommand, identifier: "posix")
            command(String(localized: "Windows (PowerShell)"), HostServiceUpdates.windowsInstallCommand, identifier: "windows")
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
