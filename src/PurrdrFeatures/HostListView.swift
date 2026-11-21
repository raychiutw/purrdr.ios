import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 主機清單(行為規格 F1.1;HIG 檢核 20.3):sheet,點一台就選取並回到 Agent 列表。
///
/// 新增、編輯、分享(QR code)與匯入都在同一個 sheet 內 push,不疊第二個 sheet。
/// 列尾 ⓘ 開編輯器;刪除會撤銷這支裝置的配對，滑動與選單都先確認(#235)。
public struct HostListView: View {
    let model: HostsModel
    /// 等著匯入的主機分享連結(深層連結帶進來的);開啟後清掉。
    @Binding var importURL: URL?
    /// 等著開編輯頁的主機(點了主機服務通知);開啟後清掉。
    @Binding var editHostID: UUID?
    /// 要直接開新增主機引導(Agent 列表空狀態的「新增主機」);開啟後清掉。
    @Binding var addHost: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var flow = HostListFlow()
    @State private var renaming: HostRenaming?
    @State private var actionError: String?

    public init(model: HostsModel, importURL: Binding<URL?> = .constant(nil), editHostID: Binding<UUID?> = .constant(nil), addHost: Binding<Bool> = .constant(false)) {
        self.model = model
        _importURL = importURL
        _editHostID = editHostID
        _addHost = addHost
    }

    public var body: some View {
        NavigationStack(path: $flow.path) {
            List {
                let updates = model.rows.filter { $0.hostServiceUpdate != nil }
                if !updates.isEmpty {
                    // 主機服務有新版本(#198):放在最上面，點進去看更新指令。
                    Section {
                        ForEach(updates) { row in
                            NavigationLink(value: HostRoute.hostServiceUpdate(row.id)) {
                                Label("Update the Host Service on \(row.title)", systemImage: "arrow.up.circle")
                            }
                            .accessibilityIdentifier("hosts.update.\(row.id.uuidString)")
                        }
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
                        model.enterDemo()
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
            .task { await model.checkHostServiceVersions() }
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("sheet.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") { flow.path.append(model.usesAddHostGuide ? .add : .addInEditor(nil)) }
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
            .confirmationDialog(
                deletionTitle, isPresented: deletionBinding, titleVisibility: .visible, presenting: flow.pendingDeletion
            ) { request in
                Button("Remove Host", role: .destructive) { confirmDeletion(request) }
                    .accessibilityIdentifier("hosts.delete.confirm")
                Button("Cancel", role: .cancel) { flow.cancelDeletion() }
            } message: { _ in
                Text("This host’s settings and keys are removed from this device, and this device’s pairing is revoked. If Purrdr added this device’s public key to the host, that key is removed too; nothing else on the host changes.")
            }
        }
        .onAppear(perform: openPendingImport)
        .onChange(of: importURL) { openPendingImport() }
        .onAppear(perform: openPendingEditor)
        .onChange(of: editHostID) { openPendingEditor() }
        .onAppear(perform: openPendingAdd)
        .onChange(of: addHost) { openPendingAdd() }
    }

    private func hostRow(_ row: HostRow) -> some View {
        HStack(spacing: 0) {
            selectButton(row)
            // ⓘ 是主要的編輯入口(HIG 盤點 2.2);`.borderless` 讓它只回應自己的範圍，不觸發整列的選取。
            Button {
                flow.showDetails(of: row.id)
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.large)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .accessibilityLabel(Text("\(row.title) Details"))
            .accessibilityIdentifier("hosts.info.\(row.id.uuidString)")
        }
        // context menu 頂端的動作與滑動動作一致;刪除放最後並標 destructive(HIG 20.3)。
        .swipeActions(edge: .leading) {
            if row.needsPairing {
                Button("Pair", systemImage: "link") { flow.showDetails(of: row.id) }
            } else {
                Button("Edit", systemImage: "pencil") { flow.showDetails(of: row.id) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 滑動上不用 `.destructive` role:List 會在確認前就把列移走;以系統紅標示，確認對話框裡才是 destructive。
            Button("Delete", systemImage: "trash") { flow.requestDeletion(of: row.id, name: row.title) }
                .tint(.red)
                .accessibilityIdentifier("hosts.delete")
            Button("Share", systemImage: "qrcode") { flow.path.append(.share(row.id)) }
        }
        .contextMenu {
            if row.needsPairing {
                Button("Pair…", systemImage: "link") { flow.showDetails(of: row.id) }
            } else {
                Button("Edit", systemImage: "pencil") { flow.showDetails(of: row.id) }
            }
            Button("Rename…", systemImage: "character.cursor.ibeam") { renaming = HostRenaming(id: row.id, name: row.title) }
            Button("Share…", systemImage: "qrcode") { flow.path.append(.share(row.id)) }
            if row.hostServiceUpdate != nil {
                Button("Update Host Service…", systemImage: "arrow.up.circle") { flow.path.append(.hostServiceUpdate(row.id)) }
            }
            // 主機圖示在編輯器的圖示格子選(#313:選項不放進選單)。
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { flow.requestDeletion(of: row.id, name: row.title) }
        }
    }

    private func selectButton(_ row: HostRow) -> some View {
        Button {
            // 還沒配對的 HTTPS 主機連不上：點它直接去配對。
            if row.needsPairing {
                flow.showDetails(of: row.id)
            } else {
                model.select(.host(row.id))
                dismiss()
            }
        } label: {
            HostRowView(
                title: row.title, subtitle: row.subtitle, session: row.session, isSelected: row.isSelected, icon: row.icon,
                needsPairing: row.needsPairing, hostServiceUpdate: row.hostServiceUpdate)
        }
        .accessibilityIdentifier("hosts.row.\(row.id.uuidString)")
        .accessibilityHint(row.needsPairing ? Text("Opens pairing for this host.") : Text(verbatim: ""))
    }

    private func destination(_ route: HostRoute) -> some View {
        Group {
            switch route {
            case .add:
                AddHostGuideScreen(make: model.makeAddHostGuide) { host in
                    saved(host)
                } onCancel: {
                    flow.path.removeLast()
                } onOpenEditor: { method in
                    // 引導還沒涵蓋這種連線方式:換成主機編輯頁(預選該方式)。
                    flow.path = [.addInEditor(method)]
                }
            case .addInEditor, .edit:
                HostEditorView(
                    model: model.makeEditor(
                        editing: route.hostID.flatMap { id in model.hosts.first { $0.id == id } }, method: route.addMethod),
                    hostSettings: route.hostID.flatMap(model.hostSettings(for:)),
                    hostStatusConnection: route.hostID.flatMap(model.hostStatusConnection(for:)),
                    onRemoveHost: removeHostAction(for: route.hostID)
                ) { host in
                    saved(host)
                } onCancel: {
                    flow.path.removeLast()
                } onIconSaved: {
                    dismiss()
                }
            case .hostServiceUpdate(let id):
                if let row = model.rows.first(where: { $0.id == id }), let version = row.hostServiceUpdate,
                    let commands = row.hostServiceUpdateCommands
                {
                    HostServiceUpdateView(hostName: row.title, version: version, commands: commands) {
                        model.dismissHostServiceUpdate(for: id)
                        flow.path.removeLast()
                    }
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
                        flow.path.removeLast()
                    } onIconSaved: {
                        dismiss()
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

    /// 主機頁已配對裝置「這支裝置」那列：回主機清單跳出移除確認(#291)。
    private func removeHostAction(for id: UUID?) -> (@MainActor () -> Void)? {
        guard let id, let host = model.hosts.first(where: { $0.id == id }) else { return nil }
        let name = host.name
        return { flow.requestDeletionFromEditor(of: id, name: name) }
    }

    private func saved(_ host: HostConfiguration) {
        model.didSave(host)
        dismiss()
    }

    private func confirmDeletion(_ request: HostDeletionRequest) {
        Task {
            do {
                try await flow.confirmDeletion(of: request) { try await model.delete($0) }
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

    private var renamingBinding: Binding<Bool> {
        // setter 留空：按鈕自己處理(見主機編輯器的 alert 同樣做法)。
        Binding { renaming != nil } set: { if !$0 { renaming = nil } }
    }

    private var deletionTitle: Text {
        Text("Remove “\(flow.pendingDeletion?.name ?? "")” from This Device?")
    }

    private var deletionBinding: Binding<Bool> {
        Binding { flow.pendingDeletion != nil } set: { if !$0 { flow.cancelDeletion() } }
    }

    private var renameText: Binding<String> {
        Binding { renaming?.name ?? "" } set: { renaming?.name = $0 }
    }

    private func openPendingImport() {
        guard let url = importURL else { return }
        importURL = nil
        flow.path = [.importLink(url)]
    }

    private func openPendingAdd() {
        guard addHost else { return }
        addHost = false
        flow.path = [model.usesAddHostGuide ? .add : .addInEditor(nil)]
    }

    private func openPendingEditor() {
        guard let id = editHostID else { return }
        editHostID = nil
        flow.openEditor(of: id)
    }
}

private struct HostRenaming {
    var id: UUID
    var name: String
}

struct HostRowView: View {
    let title: String
    let subtitle: String
    let session: String?
    let isSelected: Bool
    let icon: HostIcon
    /// 還沒配對的 HTTPS 主機(主機同步或分享連結帶來的):標示要先配對。
    var needsPairing = false
    /// 主機服務可更新到的版本(#198)。
    var hostServiceUpdate: String?

    var body: some View {
        HStack(spacing: 12) {
            HostIconBadge(icon)
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
                if needsPairing {
                    // 狀態用文字加圖示，不只靠顏色(HIG 20)。
                    Label("Not Paired on This Device", systemImage: "link.badge.plus")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryText)
                        .accessibilityIdentifier("hosts.row.needsPairing")
                }
                if let hostServiceUpdate {
                    Label("Host Service \(hostServiceUpdate) Available", systemImage: "arrow.up.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryText)
                        .accessibilityIdentifier("hosts.row.hostServiceUpdate")
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
