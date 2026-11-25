import PurrdrAgentFeatures
import SwiftUI

/// 頂列電腦圖示點開的選單內容(#500):選這個畫面看哪一台主機(檔案),不列「所有主機」。最下面是「新增主機…」。
struct HostSelectionMenu: View {
    let model: HostPickerModel
    var addHost: (() -> Void)?

    var body: some View {
        Picker(selection: selection) {
            ForEach(model.options) { option in
                HostMenuLabel(option).tag(option.id)
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
    }

    private var selection: Binding<HostSelection> {
        Binding { model.selection } set: { model.select($0) }
    }
}

/// sheet 與全螢幕畫面標題列中間的主機挑選鈕(新增聊天、登入 Shell;DESIGN.md「主機挑選鈕」):主機圖示＋名稱＋▾,
/// 點了選另一台主機。頂層 tab 的主機選擇在共用頂列(`TopBarContent.hostMenu`),不用這個。
struct SheetHostPicker: View {
    let model: HostPickerModel
    let identifier: String

    var body: some View {
        Menu {
            HostSelectionMenu(model: model)
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
            .frame(minHeight: TopBarMetrics.controlHeight)
            .background { Capsule().fill(.fill.tertiary) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // 工具列的 Menu 不會把 accessibilityValue 帶給 VoiceOver,主機名放進 label。
        .accessibilityLabel(Text("Host: \(name)"))
        .accessibilityIdentifier(identifier)
    }

    private var name: String { model.selectedOption?.name ?? "" }
}

/// 主機 tab 推進來的登入 Shell:換主機就掛斷舊的 shell、在新主機開一個新的(#245)。
struct LoginShellScreen: View {
    let hosts: HostsModel
    let picker: HostPickerModel

    var body: some View {
        LoginShellContent(model: hosts.member(for: picker.selection).loginShell(), picker: picker)
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
    let actions: TabTopBarActions

    var body: some View {
        FilesContent(model: hosts.member(for: picker.selection).folderBrowser(), picker: picker, actions: actions)
            .id(picker.selection)
    }
}

private struct FilesContent: View {
    @State private var model: FolderBrowserModel
    let picker: HostPickerModel
    let actions: TabTopBarActions

    init(model: @autoclosure () -> FolderBrowserModel, picker: HostPickerModel, actions: TabTopBarActions) {
        _model = State(wrappedValue: model())
        self.picker = picker
        self.actions = actions
    }

    var body: some View {
        FolderBrowserView(model: model, hostPicker: picker, actions: actions)
    }
}
