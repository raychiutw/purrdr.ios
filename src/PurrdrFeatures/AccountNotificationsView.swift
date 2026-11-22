import PurrdrAgentFeatures
import SwiftUI

/// 帳號頁「通知」子頁(#463、設計稿第 27 組):逐台主機的通知開關(`HostPushSection`)。
/// 還沒配對的 HTTPS 主機在這裡開配對(#295,與主機頁同一個引導);存好回到這一頁，那台的開關就能用。
struct AccountNotificationsView: View {
    let pushes: [HostPush]
    let openPlus: () -> Void
    let hosts: HostsModel?
    @State private var pairingHost: UUID?

    var body: some View {
        List {
            HostPushSection(pushes: pushes, openPlus: openPlus, pair: { pairingHost = $0 })
        }
        .appGroupedList()
        .accessibilityIdentifier("account.notifications.page")
        .navigationTitle("Notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .hostPushConfirmation(pushes)
        .navigationDestination(item: $pairingHost) { id in
            if let hosts, let host = hosts.hosts.first(where: { $0.id == id }) {
                AddHostGuideScreen(
                    make: { (try? hosts.makePairingGuide(for: host)) ?? hosts.makeAddHostGuide() },
                    onSaved: { _ in pairingHost = nil },
                    onCancel: { pairingHost = nil },
                    onAdded: { hosts.didSave($0) },
                    hostPush: { id in hosts.hostPushes.first { $0.host == .host(id) } })
            }
        }
    }
}
