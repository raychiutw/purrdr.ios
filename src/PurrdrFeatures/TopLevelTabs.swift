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
        .sharedBackgroundVisibility(.hidden)
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
                    .toolbar {
                        ToolbarItem(placement: .principal) { HostPickerButton(model: picker, identifier: "files.host", addHost: addHost) }
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

/// 主機 tab 的工具列(登入 Shell、方案用量的入口;內容之後由主機 tab 的票接手,#392)。
struct HostToolRows: View {
    let hosts: HostsModel

    var body: some View {
        Section {
            NavigationLink {
                PlanUsageScreen(make: { hosts.planUsage() })
            } label: {
                Label("Plan Usage", systemImage: "gauge.with.dots.needle.33percent")
            }
            .accessibilityIdentifier("hosts.tool.planUsage")
            if hosts.anyHostSupportsShell {
                NavigationLink {
                    LoginShellTool(hosts: hosts)
                } label: {
                    Label("Login Shell", systemImage: "apple.terminal")
                }
                .accessibilityIdentifier("hosts.tool.loginShell")
            }
        }
    }
}

/// 進畫面才建立方案用量 model(每次打開重新查一次)。
private struct PlanUsageScreen: View {
    @State private var model: PlanUsageModel

    init(make: () -> PlanUsageModel) {
        _model = State(wrappedValue: make())
    }

    var body: some View {
        PlanUsageView(model: model)
    }
}

/// 進畫面才建立登入 Shell 的主機挑選鈕(換主機掛斷舊 shell、在新主機開新的)。
private struct LoginShellTool: View {
    let hosts: HostsModel
    @State private var picker: HostPickerModel

    init(hosts: HostsModel) {
        self.hosts = hosts
        _picker = State(wrappedValue: hosts.hostPicker(for: .loginShell))
    }

    var body: some View {
        LoginShellScreen(hosts: hosts, picker: picker)
            .hidesTabBarWhenCompact()
    }
}

/// 主機 tab:頂列中間是選取中主機的選單、右上新增主機與帳號。清單與工具入口先沿用現有畫面(內容由 #392 接手)。
struct HostsTab: View {
    let hosts: HostsModel
    let member: MemberModel
    @Binding var importURL: URL?
    @Binding var editHostID: UUID?
    @Binding var addHost: Bool
    let openAccount: () -> Void
    let openAddHost: () -> Void
    let didEnterDemo: () -> Void

    var body: some View {
        HostListView(
            model: hosts,
            chrome: HostTabChrome(
                principal: AnyView(HostPickerButton(model: hosts.selectedHostPicker(), identifier: "hosts.host", addHost: openAddHost)),
                account: AnyView(AccountButton(member: member, action: openAccount)),
                tools: AnyView(HostToolRows(hosts: hosts)),
                didEnterDemo: didEnterDemo),
            importURL: $importURL, editHostID: $editHostID, addHost: $addHost)
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
