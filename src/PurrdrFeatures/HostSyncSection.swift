import SwiftUI

/// 帳號頁開通後的「主機同步」區(#30):開關、狀態、沒有 Purrdr Plus 時的訂閱入口;footer 說明同步什麼、不同步什麼。
struct HostSyncSection: View {
    let model: HostSyncModel
    let plus: SubscriptionModel?
    let member: MemberModel

    var body: some View {
        Section {
            Toggle("Sync Hosts", isOn: Binding(get: { model.isEnabled }, set: { enabled in Task { await model.setEnabled(enabled) } }))
                .accessibilityIdentifier("settings.hostSync")
            statusRow
        } header: {
            Text("Host Sync")
                .foregroundStyle(.secondaryText)
        } footer: {
            Text("Host names, addresses, user names, connection methods, and host key fingerprints sync to your other devices through your Purrdr member account. Passwords and private keys never leave this device. Requires Purrdr Plus.")
                .foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.status {
        case .off:
            EmptyView()
        case .syncing:
            LabeledContent("Status") { Text("Syncing…") }
                .accessibilityIdentifier("settings.hostSync.status")
        case .upToDate(let date):
            LabeledContent("Last Synced") { Text(date, style: .relative) }
                .accessibilityIdentifier("settings.hostSync.status")
        case .needsPlus:
            if let plus {
                NavigationLink {
                    PlusView(model: plus, member: member)
                } label: {
                    Label("Host sync needs Purrdr Plus", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("settings.hostSync.plus")
            } else {
                Text("Host sync needs Purrdr Plus")
                    .accessibilityIdentifier("settings.hostSync.plus")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: message)
                    .foregroundStyle(.secondaryText)
                Button("Try Again") { Task { await model.sync() } }
                    .accessibilityIdentifier("settings.hostSync.retry")
            }
            .accessibilityIdentifier("settings.hostSync.problem")
        }
    }
}
