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

/// 檔案 tab:選取中主機的檔案瀏覽。共用頂列(#500):電腦圖示選看哪台主機(只改選取中主機,不列所有主機)、「＋」上傳、頭像。
struct FilesTab: View {
    let hosts: HostsModel
    let member: MemberModel
    let openAccount: () -> Void
    let addHost: () -> Void

    /// 資料夾的導覽路徑(#620):第一層是家目錄,每往下一層資料夾推一個 `FolderRoute`。
    @State private var folderPath: [FolderRoute] = []
    @State private var unavailableQuery = ""
    @FocusState private var unavailableSearchFocused: Bool

    private var actions: TabTopBarActions {
        TabTopBarActions(addHost: addHost, account: AnyView(TopBarAccountButton(member: member, action: openAccount)))
    }

    var body: some View {
        NavigationStack(path: $folderPath) {
            if hosts.hasNoHostToShow {
                TabUnavailableView(
                    title: "No Hosts", systemImage: "folder",
                    message: "Add a host to browse its files.", identifier: "files.noHost")
                    .topBarPage(unavailableContent(picker: nil))
            } else if !hosts.selectedHostSupportsFiles {
                TabUnavailableView(
                    title: "Files Aren’t Available", systemImage: "folder",
                    message: "Files need an SSH connection. This host connects through the host service.",
                    identifier: "files.unsupported")
                    .topBarPage(unavailableContent(picker: hosts.screens.selectedHostPicker()))
            } else {
                FilesScreen(hosts: hosts, picker: hosts.screens.selectedHostPicker(), actions: actions, path: $folderPath)
            }
        }
    }

    /// 還不能瀏覽檔案時的頂列:同一個版型,上傳停用。
    private func unavailableContent(picker: HostPickerModel?) -> TopBarContent {
        TopBarContent(
            tab: .files, title: "Files",
            hostScope: .selected(hostName: picker?.selectedOption?.name),
            hostMenu: picker.map { AnyView(HostSelectionMenu(model: $0, addHost: addHost)) },
            hostIdentifier: "files.host",
            plus: AnyView(TopBarPlusButton(title: "Upload File", identifier: "files.upload") {}.disabled(true)),
            account: actions.account,
            search: TopBarContent.Search(text: $unavailableQuery, focus: $unavailableSearchFocused, identifier: "files.search"))
    }
}

/// 流量 tab:原「數據用量」頁(#354)的新位置。大標題「流量」,右側只有電腦圖示圓鈕(篩選主機)與頭像。
struct TrafficTab: View {
    let hosts: HostsModel
    let member: MemberModel
    let openAccount: () -> Void

    var body: some View {
        NavigationStack {
            DataUsageScreen(
                make: { hosts.screens.dataUsage() },
                account: AnyView(TopBarAccountButton(member: member, action: openAccount)))
        }
    }
}
