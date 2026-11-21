import PurrdrAgentFeatures
import SwiftUI

/// 標題列中間的主機挑選鈕(#245、DESIGN.md「主機挑選鈕」):主機圖示＋名稱＋▾,點了選另一台主機。
struct HostPickerButton: View {
    let model: HostPickerModel
    let identifier: String

    var body: some View {
        Menu {
            Picker(selection: selection) {
                ForEach(model.options) { option in
                    HostMenuLabel(option.name, icon: option.icon).tag(option.id)
                }
            } label: {
                Text("Computer")
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                HostIconBadge(model.selectedOption?.icon ?? .default, diameter: 24)
                Text(verbatim: name)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            // 跟兩旁的玻璃鈕(返回、＋)看起來一樣 44pt 高(實機回報 2026-11-20):工具列中間那格最高 36pt,
            // 玻璃鈕也是 36pt 的 frame 外多畫一圈;底色同樣往外多畫 4pt。
            .background { Capsule().fill(.fill.tertiary).padding(-4) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // 工具列的 Menu 不會把 accessibilityValue 帶給 VoiceOver,主機名放進 label(同選取中主機鈕)。
        .accessibilityLabel(Text("Computer: \(name)"))
        .accessibilityIdentifier(identifier)
    }

    private var name: String { model.selectedOption?.name ?? "" }

    private var selection: Binding<HostSelection> {
        Binding { model.selection } set: { model.select($0) }
    }
}

/// 「⋯」選單推進來的登入 Shell:換主機就掛斷舊的 shell、在新主機開一個新的(#245)。
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

/// 「⋯」選單推進來的檔案瀏覽:換主機就從那台的家目錄重新開始(#245)。
struct FilesScreen: View {
    let hosts: HostsModel
    let picker: HostPickerModel

    var body: some View {
        FilesContent(model: hosts.folderBrowser(on: picker.selection), picker: picker)
            .id(picker.selection)
    }
}

private struct FilesContent: View {
    @State private var model: FolderBrowserModel
    let picker: HostPickerModel

    init(model: @autoclosure () -> FolderBrowserModel, picker: HostPickerModel) {
        _model = State(wrappedValue: model())
        self.picker = picker
    }

    var body: some View {
        FolderBrowserView(model: model, hostPicker: picker)
    }
}
