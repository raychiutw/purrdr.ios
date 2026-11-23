import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

// 頂層 tab 的共用零件(#390、DESIGN.md「iPhone 頂層導覽」)。

/// 第二層的對話、Pane 終端機與登入 Shell 隱藏 tab bar(它們的底部已被輸入列與終端機按鍵列佔用)。
/// 只在窄視窗(iPhone、iPad 窄視窗與分割視窗);iPad 寬視窗是分欄,tab bar 留著。
private struct HidesTabBarWhenCompact: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbarVisibility(sizeClass == .compact ? .hidden : .automatic, for: .tabBar)
        #else
        content
        #endif
    }
}

extension View {
    /// 窄視窗隱藏 tab bar(對話、終端機、登入 Shell)。
    func hidesTabBarWhenCompact() -> some View {
        modifier(HidesTabBarWhenCompact())
    }
}

/// 頂端工具列的尺寸(#475):所有 tab 的按鈕、膠囊、主機選單與帳號頭像共用,不散在各畫面。
/// 聊天畫面的單行標題膠囊(`titleCapsuleHeight`)也是同一個高度(#476)。
enum TopBarMetrics {
    /// 按鈕與膠囊(含主機選單)的高度,也是 HIG 的最小觸控目標。
    static let controlHeight: CGFloat = 44
    /// 圓形按鈕(帳號頭像)的直徑。
    static let circleDiameter: CGFloat = 44
    /// 圓鈕裡的頭像直徑(與其他按鈕的符號同等大小)。
    static let avatarDiameter: CGFloat = 30
    /// 聊天畫面單行標題膠囊的高度:與其他 tab 頂端一致。
    static let titleCapsuleHeight: CGFloat = controlHeight
}

/// 每個 tab 頂列最右上角的帳號鈕(#246)。前面有別的右上動作時中間隔開,各自是獨立的玻璃。
struct AccountToolbarItem: ToolbarContent {
    let member: MemberModel
    let hasPrecedingAction: Bool
    let open: () -> Void

    var body: some ToolbarContent {
        if hasPrecedingAction {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            AccountButton(member: member, action: open)
        }
        // 頭像本身就是圓形，不再包一層玻璃。
    }
}

/// 沒有可看的主機或內容時的空與不支援狀態(`ContentUnavailableView`,不停用、不隱藏 tab)。
struct TabUnavailableView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let message: LocalizedStringKey
    let identifier: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .accessibilityIdentifier(identifier)
    }
}

/// 檔案 tab:選取中主機的檔案瀏覽。主機選單只改選取中主機(不列所有主機);右上上傳與帳號。
struct FilesTab: View {
    let hosts: HostsModel
    let member: MemberModel
    let openAccount: () -> Void
    let addHost: () -> Void

    var body: some View {
        NavigationStack {
            if hosts.hasNoHostToShow {
                TabUnavailableView(
                    title: "No Hosts", systemImage: "folder",
                    message: "Add a host to browse its files.", identifier: "files.noHost")
                    .navigationTitle("Files")
                    .toolbar { AccountToolbarItem(member: member, hasPrecedingAction: false, open: openAccount) }
            } else if !hosts.selectedHostSupportsFiles {
                let picker = hosts.selectedHostPicker()
                TabUnavailableView(
                    title: "Files Aren’t Available", systemImage: "folder",
                    message: "Files need an SSH connection. This host connects through the host service.",
                    identifier: "files.unsupported")
                    .navigationTitle("Files")
                    .toolbar(removing: .title)
                    .toolbar {
                        ToolbarItem(placement: TopNavigationView.modePlacement) { HostPickerButton(model: picker, identifier: "files.host", addHost: addHost, inToolbar: true) }
                        AccountToolbarItem(member: member, hasPrecedingAction: false, open: openAccount)
                    }
            } else {
                FilesScreen(
                    hosts: hosts, picker: hosts.selectedHostPicker(), addHost: addHost,
                    account: AnyView(AccountButton(member: member, action: openAccount)))
            }
        }
    }
}

/// 流量 tab:原「數據用量」頁(#354)的新位置。大標題「網路流量」,右上只有帳號。
struct TrafficTab: View {
    let hosts: HostsModel
    let member: MemberModel
    let openAccount: () -> Void

    var body: some View {
        NavigationStack {
            DataUsageScreen(make: { hosts.dataUsage() }, account: AnyView(AccountButton(member: member, action: openAccount)))
        }
    }
}
