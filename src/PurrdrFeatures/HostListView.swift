import PurrdrCore
import SwiftUI

/// 主機清單(行為規格 F1.1;HIG 檢核 20.3):sheet,點一台就選取並回到 Agent 列表。
///
/// 新增、編輯、分享(QR code)與匯入都在同一個 sheet 內 push,不疊第二個 sheet。
/// 刪除是使用者刻意的動作(滑動或選單再點一下),不另外確認:只刪這支裝置上的設定，主機本身不受影響，隨時可以再加回來。
public struct HostListView: View {
    let model: HostsModel
    /// 等著匯入的主機分享連結(深層連結帶進來的);開啟後清掉。
    @Binding var importURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [HostRoute] = []
    @State private var renaming: HostRenaming?
    @State private var actionError: String?

    public init(model: HostsModel, importURL: Binding<URL?> = .constant(nil)) {
        self.model = model
        _importURL = importURL
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.rows.isEmpty {
                    Section {
                        Text("Add a computer that runs herdr. Purrdr connects to it with SSH over your tailnet; nothing is exposed to the internet.")
                            .foregroundStyle(.secondaryText)
                    }
                }
                if !model.rows.isEmpty {
                    Section {
                        ForEach(model.rows) { row in
                            hostRow(row)
                        }
                    }
                }
                Section {
                    Button {
                        model.select(.demo)
                        dismiss()
                    } label: {
                        HostRowView(
                            title: String(localized: "Demo"), subtitle: String(localized: "Sample conversations, no computer connected"),
                            session: nil, isSelected: model.selection == .demo, icon: .default)
                    }
                    .accessibilityIdentifier("hosts.demo")
                }
                if let message = actionError ?? model.loadError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("hosts.error")
                    }
                }
            }
            .accessibilityIdentifier("sheet.hosts")
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // 回到列表的入口旁標示需要處理的 workspace 數(行為規格 F2.8)。
                    HStack(spacing: 6) {
                        AttentionBadge(count: model.agentList.attentionCount)
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("sheet.done")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") { path.append(.add) }
                        .accessibilityIdentifier("hosts.add")
                }
            }
            .navigationDestination(for: HostRoute.self) { route in
                destination(route)
            }
            .alert("Rename Host", isPresented: renamingBinding, presenting: renaming) { _ in
                TextField("Name", text: renameText)
                    .accessibilityIdentifier("hosts.rename.name")
                Button("Cancel", role: .cancel) {}
                // 讀目前的 `renaming`(含使用者輸入的名稱);`presenting` 傳進來的是 alert 打開當下的快照，會存回舊名稱。
                Button("Rename") { if let renaming { rename(renaming) } }
                    .accessibilityIdentifier("hosts.rename.confirm")
            } message: { _ in
                Text("The name is only used on this device.")
            }
        }
        .onAppear(perform: openPendingImport)
        .onChange(of: importURL) { openPendingImport() }
    }

    private func hostRow(_ row: HostRow) -> some View {
        Button {
            model.select(.host(row.id))
            dismiss()
        } label: {
            HostRowView(title: row.title, subtitle: row.subtitle, session: row.session, isSelected: row.isSelected, icon: row.icon)
        }
        .accessibilityIdentifier("hosts.row.\(row.id.uuidString)")
        // context menu 頂端的動作與滑動動作一致;刪除放最後並標 destructive(HIG 20.3)。
        .swipeActions(edge: .leading) {
            Button("Edit", systemImage: "pencil") { path.append(.edit(row.id)) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(row.id) }
                .accessibilityIdentifier("hosts.delete")
            Button("Share", systemImage: "qrcode") { path.append(.share(row.id)) }
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { path.append(.edit(row.id)) }
            Button("Rename…", systemImage: "character.cursor.ibeam") { renaming = HostRenaming(id: row.id, name: row.title) }
            Button("Share…", systemImage: "qrcode") { path.append(.share(row.id)) }
            // 主機圖示(#37 故事 5):只存在這支裝置，讓多台主機的列一眼分得出來。
            Picker(selection: iconBinding(row.id)) {
                ForEach(HostIcon.allCases, id: \.self) { icon in
                    Label(icon.title, systemImage: icon.symbol)
                }
            } label: {
                Label("Icon", systemImage: row.icon.symbol)
            }
            .pickerStyle(.menu)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { delete(row.id) }
        }
    }

    private func destination(_ route: HostRoute) -> some View {
        Group {
            switch route {
            case .add, .edit:
                HostEditorView(model: model.makeEditor(editing: route.hostID.flatMap { id in model.hosts.first { $0.id == id } })) { host in
                    saved(host)
                } onCancel: {
                    path.removeLast()
                }
            case .share(let id):
                if let host = model.hosts.first(where: { $0.id == id }), let link = model.shareLink(for: id) {
                    HostShareView(name: host.name, link: link)
                }
            case .importLink(let url):
                if let editor = try? model.makeImportEditor(url) {
                    HostEditorView(model: editor) { host in
                        saved(host)
                    } onCancel: {
                        path.removeLast()
                    }
                } else {
                    ContentUnavailableView(
                        "Can’t Add This Host", systemImage: "qrcode",
                        description: Text("This link isn’t a Purrdr host, or it was made by a newer version of Purrdr."))
                        .accessibilityIdentifier("hosts.importFailed")
                }
            }
        }
        // 主機編輯器的「測試連線」也可能遇到 check mode;sheet 蓋住 Agent 列表，所以這裡也要顯示。
        .tailscaleCheckPrompt(model.tailscaleCheck)
    }

    private func saved(_ host: HostConfiguration) {
        model.didSave(host)
        dismiss()
    }

    private func delete(_ id: UUID) {
        Task {
            do {
                try await model.delete(id)
                actionError = nil
            } catch {
                actionError = String(localized: "Couldn’t remove this host from this device. \(error.localizedDescription)")
            }
        }
    }

    private func rename(_ renaming: HostRenaming) {
        do {
            try model.rename(renaming.id, to: renaming.name)
            actionError = nil
        } catch HostManagementError.emptyName {
            actionError = String(localized: "A host needs a name.")
        } catch {
            actionError = String(localized: "Couldn’t rename this host. \(error.localizedDescription)")
        }
        self.renaming = nil
    }

    private func iconBinding(_ id: UUID) -> Binding<HostIcon> {
        Binding { model.icon(for: id) } set: { model.setIcon($0, for: id) }
    }

    private var renamingBinding: Binding<Bool> {
        // setter 留空：按鈕自己處理(見主機編輯器的 alert 同樣做法)。
        Binding { renaming != nil } set: { if !$0 { renaming = nil } }
    }

    private var renameText: Binding<String> {
        Binding { renaming?.name ?? "" } set: { renaming?.name = $0 }
    }

    private func openPendingImport() {
        guard let url = importURL else { return }
        importURL = nil
        path = [.importLink(url)]
    }
}

private struct HostRenaming {
    var id: UUID
    var name: String
}

enum HostRoute: Hashable {
    case add
    case edit(UUID)
    case share(UUID)
    case importLink(URL)

    var hostID: UUID? {
        if case .edit(let id) = self { return id }
        return nil
    }
}

struct HostRowView: View {
    let title: String
    let subtitle: String
    let session: String?
    let isSelected: Bool
    let icon: HostIcon

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon.symbol)
                .foregroundStyle(Color.secondary)
                .frame(minWidth: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // `Color.primary`/`Color.secondaryText`:列是 Button,階層式的 `.primary`/`.secondary` 會跟著按鈕變成 tint,
                // 副標成了淡粉紅、對比不足(#35)。
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
                    .truncationMode(.middle)
                if let session {
                    Text("Session: \(session)")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
