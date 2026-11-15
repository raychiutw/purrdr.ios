import PurrdrCore
import SwiftUI

/// 主機清單(行為規格 F1.1):sheet,點一台就選取並回到 Agent 列表;新增與編輯在同一個 sheet 內 push。
public struct HostListView: View {
    let model: HostsModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [HostRoute] = []

    public init(model: HostsModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.rows.isEmpty {
                    Section {
                        Text("Add a computer that runs herdr. Purrdr connects to it with SSH over your tailnet; nothing is exposed to the internet.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !model.rows.isEmpty {
                    Section {
                        ForEach(model.rows) { row in
                            Button {
                                model.select(.host(row.id))
                                dismiss()
                            } label: {
                                HostRowView(title: row.title, subtitle: row.subtitle, session: row.session, isSelected: row.isSelected)
                            }
                            .accessibilityIdentifier("hosts.row.\(row.id.uuidString)")
                            .swipeActions(edge: .leading) {
                                Button("Edit", systemImage: "pencil") { path.append(.edit(row.id)) }
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { path.append(.edit(row.id)) }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        model.select(.demo)
                        dismiss()
                    } label: {
                        HostRowView(
                            title: "Demo", subtitle: String(localized: "Sample conversations, no computer connected"),
                            session: nil, isSelected: model.selection == .demo)
                    }
                    .accessibilityIdentifier("hosts.demo")
                }
                if let loadError = model.loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("sheet.hosts")
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("sheet.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") { path.append(.add) }
                        .accessibilityIdentifier("hosts.add")
                }
            }
            .navigationDestination(for: HostRoute.self) { route in
                HostEditorView(model: model.makeEditor(editing: route.hostID.flatMap { id in model.hosts.first { $0.id == id } })) { host in
                    model.didSave(host)
                    dismiss()
                } onCancel: {
                    path.removeLast()
                }
            }
        }
        // 主機編輯器的「測試連線」也可能遇到 check mode;sheet 蓋住 Agent 列表，所以這裡也要顯示。
        .tailscaleCheckPrompt(model.tailscaleCheck)
    }
}

enum HostRoute: Hashable {
    case add
    case edit(UUID)

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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                if let session {
                    Text("Session: \(session)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
