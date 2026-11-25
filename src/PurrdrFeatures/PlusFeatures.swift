import SwiftUI

/// Purrdr Plus 包含的功能(#323):已訂閱頁逐項列出,點了到帳號頁對應設定。
enum PlusFeature: String, CaseIterable, Identifiable {
    case notifications
    case hostSync
    case devices

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .notifications: "bell.badge"
        case .hostSync: "arrow.triangle.2.circlepath"
        case .devices: "iphone"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .notifications: "Notifications"
        case .hostSync: "Host Sync"
        case .devices: "Notification Devices"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .notifications: "Get notified when an agent needs you, finishes, or may be stuck"
        case .hostSync: "Sync your host list between your iPhone and iPad"
        case .devices: "Rename or turn off the devices that get notifications"
        }
    }
}

/// 功能列尾的目前狀態,取自通知開啟的主機數、主機同步開關與通知裝置數。
struct PlusFeatureStatus: Equatable {
    var notifyingHostCount: Int
    var isHostSyncOn: Bool
    /// 還沒讀到清單時是 `nil`。
    var deviceCount: Int?

    func value(for feature: PlusFeature) -> String? {
        switch feature {
        case .notifications:
            notifyingHostCount == 0 ? String(localized: "Off") : String(localized: "\(notifyingHostCount) hosts")
        case .hostSync:
            isHostSyncOn ? String(localized: "On") : String(localized: "Off")
        case .devices:
            deviceCount.map { String(localized: "\($0) devices") }
        }
    }
}

/// 付費牆要的功能列資料與點擊去向(由帳號頁或頂層導覽提供)。
///
/// 功能列點了往右 push 對應的頁面(#619,列尾 > 一律 push):不關付費牆、不換成帳號 sheet。
struct PlusFeatureLinks {
    var status: PlusFeatureStatus
    /// 一項功能的目的頁。
    var destination: (PlusFeature) -> AnyView
}

/// Plus 功能列推入的頁面:通知(逐台主機開關)、主機同步、通知裝置。帳號頁與從頂層開的付費牆共用。
struct PlusFeatureDestination: View {
    let feature: PlusFeature
    let member: MemberModel
    let plus: SubscriptionModel?
    let pushes: [HostPush]
    let pushDevices: PushDevicesModel?
    let hostSync: HostSyncModel?
    let hosts: HostsModel?
    let canRename: Bool

    var body: some View {
        switch feature {
        case .notifications:
            // 已在付費牆上,所以通知頁裡「需要 Plus」的入口不另外開。
            AccountNotificationsView(pushes: pushes, openPlus: {}, hosts: hosts)
        case .hostSync:
            if let hostSync {
                List {
                    Section {
                        HostSyncRows(model: hostSync, plus: plus, member: member)
                    } footer: {
                        Text(HostSyncRows.footer).foregroundStyle(.secondaryText)
                    }
                }
                .appGroupedList()
                .accessibilityIdentifier("plus.hostSync.page")
                .navigationTitle("Host Sync")
            }
        case .devices:
            if let pushDevices {
                PushDevicesView(model: pushDevices, canRename: canRename)
            }
        }
    }
}
