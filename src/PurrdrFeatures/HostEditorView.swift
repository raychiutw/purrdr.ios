import PurrdrCore
import SwiftUI

/// 新增／編輯主機(行為規格 F1.2、§8.2;HIG 檢核 20.3)。
///
/// 儲存前必須通過連線測試;第一次連線以 alert 確認 host key 指紋;herdr 過舊時確認後更新。
struct HostEditorView: View {
    @State private var model: HostEditorModel
    @State private var confirmingDiscard = false
    let onSaved: (HostConfiguration) -> Void
    let onCancel: () -> Void

    init(model: HostEditorModel, onSaved: @escaping (HostConfiguration) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    var body: some View {
        Form {
            Section("Host") {
                field("Name", text: $model.name, prompt: "Studio Mac", identifier: "name")
                field("Address", text: $model.address, prompt: "my-mac or 100.64.0.1", identifier: "address")
                    .addressKeyboard()
                field("Port", text: $model.port, prompt: "22", identifier: "port")
                    .numberKeyboard()
                field("User Name", text: $model.username, prompt: "Your user on that computer", identifier: "username")
            }

            Section {
                LabeledContent("Connection", value: "Tailscale SSH")
            } footer: {
                Text("Tailscale checks who you are on your tailnet, so no key or password is needed.")
            }

            Section {
                field("herdr Path", text: $model.herdrPath, prompt: "herdr", identifier: "herdrPath")
                field("Session", text: $model.herdrSession, prompt: "Default", identifier: "herdrSession")
            } header: {
                Text("herdr")
            } footer: {
                Text("Leave Session blank unless this computer runs more than one herdr session.")
            }

            Section {
                testStatus
            } footer: {
                Text("Purrdr tests the connection before saving the host.")
            }

            if let fingerprint = model.hostKeyFingerprint {
                Section {
                    Text(fingerprint.description)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("hostEditor.fingerprint")
                } header: {
                    Text("Host Key")
                } footer: {
                    Text("To compare, run ssh-keygen -lf on a host key file on that computer.")
                }
            }
        }
        .navigationTitle(model.isEditing ? "Edit Host" : "Add Host")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        #endif
        .interactiveDismissDisabled(model.hasChanges)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if model.hasChanges { confirmingDiscard = true } else { onCancel() }
                }
                .confirmationDialog("Discard your changes to this host?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { onCancel() }
                    Button("Keep Editing", role: .cancel) {}
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let host = model.save() { onSaved(host) }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("hostEditor.save")
            }
        }
        .alert("Trust This Host?", isPresented: presenting(\.isConfirmingHostKey)) {
            Button("Trust") { Task { await model.trustPresentedHostKey() } }
            Button("Cancel", role: .cancel) { model.dismissPrompt() }
        } message: {
            if case .confirmHostKey(let fingerprint) = model.phase {
                Text("This is the first connection to \(model.address). It identifies itself with this key:\n\n\(fingerprint.description)\n\nTrust it only if it matches ssh-keygen -lf on that computer.")
            }
        }
        .alert("Host Key Changed", isPresented: presenting(\.isHostKeyChanged)) {
            Button("Trust New Key", role: .destructive) { Task { await model.trustPresentedHostKey() } }
            Button("Cancel", role: .cancel) { model.dismissPrompt() }
        } message: {
            if case .hostKeyChanged(let presented, let pinned) = model.phase {
                Text("This host now identifies itself with a different key. Reinstalling or resetting it does this, and so does someone intercepting the connection. If you didn’t reinstall or reset it, stop.\n\nPresented key:\n\(presented.description)\n\nSaved key:\n\(pinned.description)")
            }
        }
        .alert("Update herdr?", isPresented: presenting(\.isOutdated)) {
            Button("Update") { Task { await model.updateHerdr() } }
            Button("Cancel", role: .cancel) { model.dismissPrompt() }
        } message: {
            if case .needsUpdate(let version) = model.phase {
                Text("This host has herdr \(version.description). Purrdr needs \(HerdrVersion.minimumSupported.description) or later. Purrdr will run “herdr update --handoff” as \(model.username)@\(model.address).")
            }
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch model.phase {
        case .testing:
            HStack {
                ProgressView()
                Text("Connecting to \(model.address)…")
                Spacer()
                Button("Cancel") { model.cancelTest() }
            }
            .accessibilityElement(children: .contain)
        case .updating:
            HStack {
                ProgressView()
                Text("Updating herdr on \(model.address)…")
            }
        default:
            Button("Test Connection") { Task { await model.test() } }
                .disabled(!model.canTest)
                .accessibilityIdentifier("hostEditor.test")
            switch model.phase {
            case .tested(let report):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected · herdr \(report.herdrVersion.description) · \(report.operatingSystem.displayName)")
                        Text(report.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .accessibilityIdentifier("hostEditor.result")
            case .failed(let message):
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .accessibilityIdentifier("hostEditor.result")
            default:
                EmptyView()
            }
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, identifier: String) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .plainTextInput()
                .accessibilityIdentifier("hostEditor.\(identifier)")
        }
    }

    /// alert 用的 binding:關閉由按鈕自己處理(按鈕動作與關閉的先後順序不保證)。
    private func presenting(_ keyPath: KeyPath<HostEditorModel.Phase, Bool>) -> Binding<Bool> {
        Binding(get: { model.phase[keyPath: keyPath] }, set: { _ in })
    }
}

extension HostEditorModel.Phase {
    var isConfirmingHostKey: Bool {
        if case .confirmHostKey = self { return true }
        return false
    }

    var isHostKeyChanged: Bool {
        if case .hostKeyChanged = self { return true }
        return false
    }

    var isOutdated: Bool {
        if case .needsUpdate = self { return true }
        return false
    }
}

extension HostOperatingSystem {
    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        }
    }
}

extension HostProbeReport {
    /// 「3 agents · Agent integrations: claude, hermes」
    var summary: String {
        let agents = String(localized: "\(agentCount) agents")
        guard !integrations.isEmpty else { return agents }
        return agents + " · " + String(localized: "Integrations: \(integrations.map(\.label).joined(separator: ", "))")
    }
}

private extension View {
    func addressKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL)
        #else
        self
        #endif
    }

    func numberKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }

    func plainTextInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
