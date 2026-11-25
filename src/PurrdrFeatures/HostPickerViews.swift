import PurrdrAgentFeatures
import SwiftUI

/// 頂列電腦圖示點開的選單內容(#500):選這個畫面看哪一台主機(檔案),不列「所有主機」。最下面是「新增主機…」。
struct HostSelectionMenu: View {
    let model: HostPickerModel
    var addHost: (() -> Void)?
    /// 選到需要重新確認的主機(#572)時呼叫(帶那台主機的 id):主機 tab 開編輯頁走確認流程。
    var reconfirm: ((UUID) -> Void)?

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
        Binding { model.selection } set: { host in
            if let id = model.choose(host) { reconfirm?(id) }
        }
    }
}

/// 新增聊天與登入 Shell 右上的電腦圖示選單(#621):選這個畫面用哪一台主機。全 app 選主機只有這一種長相
/// (同頂列的電腦圖示),系統工具列按鈕、不自畫膠囊。
struct HostMenuButton: View {
    let model: HostPickerModel
    let identifier: String

    var body: some View {
        Menu {
            HostSelectionMenu(model: model)
        } label: {
            Image(systemName: "desktopcomputer")
        }
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

/// 檔案 tab 的檔案瀏覽:換主機就從那台的家目錄重新開始(#245)。每一層資料夾是 push(#620),路徑由 `FilesTab` 的 `NavigationStack` 持有。
struct FilesScreen: View {
    let hosts: HostsModel
    let picker: HostPickerModel
    let actions: TabTopBarActions
    @Binding var path: [FolderRoute]

    var body: some View {
        FilesContent(model: hosts.member(for: picker.selection).folderBrowser(), picker: picker, actions: actions, path: $path)
            .id(picker.selection)
            .onChange(of: picker.selection) { path = [] }
    }
}

private struct FilesContent: View {
    @State private var model: FolderBrowserModel
    let picker: HostPickerModel
    let actions: TabTopBarActions
    @Binding var path: [FolderRoute]

    init(model: @autoclosure () -> FolderBrowserModel, picker: HostPickerModel, actions: TabTopBarActions, path: Binding<[FolderRoute]>) {
        _model = State(wrappedValue: model())
        self.picker = picker
        self.actions = actions
        _path = path
    }

    var body: some View {
        FolderBrowserView(model: model, level: .root(hostPicker: picker, actions: actions), path: $path, rootPath: model.path)
            .navigationDestination(for: FolderRoute.self) { route in
                FolderLevelView(parent: model, route: route, path: $path)
            }
    }
}

/// push 進來的一層資料夾:自己一個 model(從那個資料夾開始),離開時系統丟掉。
private struct FolderLevelView: View {
    @State private var model: FolderBrowserModel
    @Binding var path: [FolderRoute]
    let rootPath: String?

    init(parent: FolderBrowserModel, route: FolderRoute, path: Binding<[FolderRoute]>) {
        _model = State(wrappedValue: parent.child(at: route.path))
        _path = path
        rootPath = parent.path
    }

    var body: some View {
        FolderBrowserView(model: model, level: .pushed, path: $path, rootPath: rootPath)
    }
}
