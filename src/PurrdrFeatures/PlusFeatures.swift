import SwiftUI

/// Purrdr Plus 包含的功能(#323):已訂閱頁逐項列出,點了到帳號頁對應設定。
enum PlusFeature: String, CaseIterable, Identifiable {
    case notifications
    case hostSync
    case devices

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .notifications: "bell.badge.fill"
        case .hostSync: "arrow.triangle.2.circlepath"
        case .devices: "iphone"
        }
    }

    var color: Color {
        switch self {
        case .notifications: .orange
        case .hostSync: .blue
        case .devices: .green
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
            switch notifyingHostCount {
            case 0: String(localized: "Off")
            case 1: String(localized: "1 host")
            default: String(localized: "\(notifyingHostCount) hosts")
            }
        case .hostSync:
            isHostSyncOn ? String(localized: "On") : String(localized: "Off")
        case .devices:
            deviceCount.map { $0 == 1 ? String(localized: "1 device") : String(localized: "\($0) devices") }
        }
    }
}

/// 付費牆要的功能列資料與點擊去向(由帳號頁或頂層導覽提供)。
struct PlusFeatureLinks {
    var status: PlusFeatureStatus
    /// 先關掉付費牆(推入的頁面)再前往;sheet 由前往的動作自己換掉。
    var dismissesOnOpen = false
    var open: (PlusFeature) -> Void
}
