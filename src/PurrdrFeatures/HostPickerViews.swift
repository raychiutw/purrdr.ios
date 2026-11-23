import PurrdrAgentFeatures
import SwiftUI

/// 標題列中間的主機挑選鈕(#245、DESIGN.md「主機挑選鈕」):主機圖示＋名稱＋▾,點了選另一台主機。
struct HostPickerButton: View {
    let model: HostPickerModel
    let identifier: String
    /// 選單最下面的「新增主機…」(頂層 tab 的主機選單才有,#390)。
    var addHost: (() -> Void)?
    /// 放在工具列(頂層 tab 的左上,#475):膠囊底色由工具列的玻璃提供;否則(sheet 內)自己畫底色。
    var inToolbar = false

    var body: some View {
        Menu {
            Picker(selection: selection) {
                ForEach(model.options) { option in
                    HostMenuLabel(option.name, icon: option.icon).tag(option.id)
                }
            } label: {
                Text("Host")
            }
            .pickerStyle(.inline)
            if let addHost {
                Divider()
                Button("Add Host…", systemImage: "plus", action: addHost)
                    .accessibilityIdentifier("hostMenu.addHost")
            }
        } label: {
            HStack(spacing: 6) {
                HostIconBadge(model.selectedOption?.icon ?? .default, diameter: 24)
                Text(verbatim: name)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            // 所有 tab 的主機選單與其他按鈕同高(#475)。
            .frame(minHeight: TopBarMetrics.controlHeight)
            .background { if !inToolbar { Capsule().fill(.fill.tertiary) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // 頂層 tab 的 tint 是主色(綠):工具列裡的選單文字照一般文字色,與聊天 tab 的主機選單一致(#475)。
        .tint(inToolbar ? Color.primary : nil)
        // 工具列的 Menu 不會把 accessibilityValue 帶給 VoiceOver,主機名放進 label(同選取中主機鈕)。
        .accessibilityLabel(Text("Host: \(name)"))
        .accessibilityIdentifier(identifier)
    }

    private var name: String { model.selectedOption?.name ?? "" }

    private var selection: Binding<HostSelection> {
        Binding { model.selection } set: { model.select($0) }
    }
}

/// 主機 tab 推進來的登入 Shell:換主機就掛斷舊的 shell、在新主機開一個新的(#245)。
struct LoginShellScreen: View {
    let hosts: HostsModel
    let picker: HostPickerModel

    var body: some View {
        LoginShellContent(model: hosts.loginShell(on: picker.selection), picker: picker)
            .id(picker.selection)
    }
}

private struct LoginShellContent: View {
    @State private var model: LoginShellModel
    let picker: HostPickerModel

    init(model: @autoclosure () -> LoginShellModel, picker: HostPickerModel) {
        _model = State(wrappedValue: model())
        self.picker = picker
    }

    var body: some View {
        #if canImport(UIKit)
        TerminalSessionView(model: model, hostPicker: picker)
        #else
        Text(verbatim: model.title)
        #endif
    }
}

/// 檔案 tab 的檔案瀏覽:換主機就從那台的家目錄重新開始(#245)。
struct FilesScreen: View {
    let hosts: HostsModel
    let picker: HostPickerModel
    let addHost: (() -> Void)?
    let account: AnyView?

    init(hosts: HostsModel, picker: HostPickerModel, addHost: (() -> Void)? = nil, account: AnyView? = nil) {
        self.hosts = hosts
        self.picker = picker
        self.addHost = addHost
        self.account = account
    }

    var body: some View {
        FilesContent(model: hosts.folderBrowser(on: picker.selection), picker: picker, addHost: addHost, account: account)
            .id(picker.selection)
    }
}

private struct FilesContent: View {
    @State private var model: FolderBrowserModel
    let picker: HostPickerModel
    let addHost: (() -> Void)?
    let account: AnyView?

    init(model: @autoclosure () -> FolderBrowserModel, picker: HostPickerModel, addHost: (() -> Void)?, account: AnyView?) {
        _model = State(wrappedValue: model())
        self.picker = picker
        self.addHost = addHost
        self.account = account
    }

    var body: some View {
        FolderBrowserView(model: model, hostPicker: picker, addHost: addHost, account: account)
    }
}
