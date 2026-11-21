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
            Text("Purrdr host service \(version) is ready for \(hostName). To update now, run this on that computer:")
        } else {
            Text("Purrdr host service \(version) is ready for \(hostName) (now \(commands.installedVersion)). Run the install command on that computer once; after that it updates itself.")
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

/// 主機服務太舊、某個功能還不能用:一句動作說明加依已安裝版本的更新指令(可選取、可拷貝)。
/// 給新增聊天、變更頁這類「要更新才能用」的地方共用;`identifier` 區分各處的 accessibility id。
struct HostServiceCommandRows: View {
    let message: LocalizedStringKey
    let commands: HostServiceUpdateCommands
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "arrow.down.circle")
            command(String(localized: "macOS and Linux"), commands.posix, key: "posix")
            command(String(localized: "Windows (PowerShell)"), commands.windows, key: "windows")
        }
        .accessibilityIdentifier(identifier)
    }

    private func command(_ title: String, _ command: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
            Text(verbatim: command)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            Button("Copy Command", systemImage: "document.on.document") { Clipboard.copy(command) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("\(identifier).copy.\(key)")
        }
    }
}
