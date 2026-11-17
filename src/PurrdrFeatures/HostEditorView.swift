import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 新增／編輯主機(行為規格 F1.2、§8.2、§8.3;HIG 檢核 20.3)。
///
/// 儲存前必須通過連線測試;第一次連線以 alert 確認 host key 指紋;herdr 過舊時確認後更新。
/// OpenSSH 主機可用這支裝置的金鑰、匯入的私鑰或密碼登入;公鑰與加入指令在同一個 sheet 內 push。
/// HTTPS 主機(ADR-0010)只填位址與配對碼;掃主機配對指令的 QR code 會帶入兩者(系統相機開 `purrdr://pair?…`)。
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
            Section {
                field("Name", text: $model.name, prompt: "Studio Mac", identifier: "name")
                if model.connectionMethod == .https {
                    field("Address", text: $model.address, prompt: "my-mac.tailnet.ts.net", identifier: "address")
                        .addressKeyboard()
                    field(
                        "Pairing Code", text: $model.pairingCode, prompt: model.isEditing ? "Unchanged" : "K7QM-2XPA",
                        identifier: "pairingCode")
                } else {
                    field("Address", text: $model.address, prompt: "my-mac or 100.64.0.1", identifier: "address")
                        .addressKeyboard()
                    field("Port", text: $model.port, prompt: "22", identifier: "port")
                        .numberKeyboard()
                    field("User Name", text: $model.username, prompt: "Your user on that computer", identifier: "username")
                }
            } header: {
                Text("Host")
                    .foregroundStyle(.secondaryText)
            }

            Section {
                Picker("Connection", selection: $model.connectionMethod) {
                    Text(verbatim: "Tailscale SSH").tag(HostConfiguration.ConnectionMethod.tailscaleSSH)
                    Text(verbatim: "OpenSSH").tag(HostConfiguration.ConnectionMethod.openSSH)
                    Text(verbatim: "HTTPS").tag(HostConfiguration.ConnectionMethod.https)
                }
                // 選單樣式：AX5 字級時分段控制會把「Tailscale SSH」截斷。
                .accessibilityIdentifier("hostEditor.connection")
            } header: {
                Text("Connection")
                    .foregroundStyle(.secondaryText)
            } footer: {
                Group {
                    switch model.connectionMethod {
                    case .tailscaleSSH:
                        Text("Tailscale checks who you are on your tailnet, so no key or password is needed.")
                    case .openSSH:
                        Text("Purrdr signs in to the host’s own SSH server with a key or password.")
                    case .https:
                        Text("On the host, run purrdr-host-service pair, then scan its QR code with the Camera app, or enter the address and pairing code it shows. Login Shell and Files aren’t available over HTTPS.")
                    }
                }
                .foregroundStyle(.secondaryText)
            }

            if model.connectionMethod == .openSSH {
                signInSection
            }

            // HTTPS 的 herdr session 由主機服務決定。
            if model.connectionMethod != .https {
                Section {
                    field("herdr Path", text: $model.herdrPath, prompt: "herdr", identifier: "herdrPath")
                    field("Session", text: $model.herdrSession, prompt: "Default", identifier: "herdrSession")
                } header: {
                    Text("herdr")
                        .foregroundStyle(.secondaryText)
                } footer: {
                    Text("Leave Session blank unless this computer runs more than one herdr session.")
                        .foregroundStyle(.secondaryText)
                }
            }

            Section {
                testStatus
            } footer: {
                Text("Purrdr tests the connection before saving the host.")
                    .foregroundStyle(.secondaryText)
            }

            if let fingerprint = model.hostKeyFingerprint {
                Section {
                    Text(fingerprint.description)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("hostEditor.fingerprint")
                } header: {
                    Text("Host Key")
                        .foregroundStyle(.secondaryText)
                } footer: {
                    Text("To compare, run ssh-keygen -lf on a host key file on that computer.")
                        .foregroundStyle(.secondaryText)
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
                Text("This host has herdr \(version.description). Purrdr needs \(HerdrVersion.minimumSupported.description) or later. Purrdr will update herdr as \(model.username)@\(model.address).")
            }
        }
    }

    // MARK: - OpenSSH 登入

    @ViewBuilder
    private var signInSection: some View {
        Section {
            Picker("Sign In With", selection: $model.authentication) {
                Text("This Device’s Key").tag(HostConfiguration.OpenSSHAuthentication.deviceKey)
                Text("Imported Key").tag(HostConfiguration.OpenSSHAuthentication.importedKey)
                Text("Password").tag(HostConfiguration.OpenSSHAuthentication.password)
            }
            .accessibilityIdentifier("hostEditor.signIn")
            switch model.authentication {
            case .deviceKey: deviceKeyRows
            case .importedKey: importedKeyRows
            case .password:
                LabeledContent("Password") {
                    SecureField("Password", text: $model.password, prompt: Text(model.hasStoredSecret ? "Unchanged" : "Required"))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("hostEditor.password")
                }
            }
        } header: {
            Text("Sign In")
                .foregroundStyle(.secondaryText)
        } footer: {
            Group {
                switch model.authentication {
                case .deviceKey:
                    Text("The key is created in this device’s Secure Enclave, and the private key never leaves it. Add its public key to the host first.")
                case .importedKey:
                    Text("Paste an ed25519 or ECDSA private key in OpenSSH format. RSA keys and keys protected by a passphrase aren’t supported. The key is kept in this device’s keychain.")
                case .password:
                    Text("The password is kept in this device’s keychain.")
                }
            }
            .foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private var deviceKeyRows: some View {
        if let publicKey = model.devicePublicKey {
            NavigationLink {
                DevicePublicKeyView(publicKey: publicKey, username: model.username)
            } label: {
                LabeledContent {
                    Text(verbatim: publicKey.fingerprint.description)
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    Text("Public Key")
                }
            }
            .accessibilityIdentifier("hostEditor.devicePublicKey")
        } else if let problem = model.deviceKeyProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.errorText)
        } else {
            ProgressView()
                .task { await model.loadDeviceKey() }
        }
    }

    @ViewBuilder
    private var importedKeyRows: some View {
        if case .valid(let publicKey) = model.keyCheck {
            LabeledContent {
                Button("Replace") { model.privateKeyText = "" }
                    .accessibilityIdentifier("hostEditor.replaceKey")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenSSH private key, \(model.privateKeyText.split(whereSeparator: \.isNewline).count) lines")
                    Text(verbatim: publicKey.fingerprint.description)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondaryText)
                        .textSelection(.enabled)
                }
            }
            .accessibilityIdentifier("hostEditor.importedKey")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Private Key")
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                TextEditor(text: $model.privateKeyText)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 120)
                    .autocorrectionDisabled()
                    .plainTextInput()
                    .accessibilityLabel("Private Key")
                    .accessibilityIdentifier("hostEditor.privateKey")
                if model.privateKeyText.isEmpty && model.hasStoredSecret {
                    Text("Leave blank to keep the saved key.")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                }
            }
            .task(id: model.privateKeyText) {
                // 打字時不要每個字都檢查一次。
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.checkKey()
            }
        }
        switch model.keyCheck {
        case .unchecked:
            HStack {
                ProgressView()
                Text("Checking key…")
            }
        case .invalid(let error):
            Label {
                Text(HostErrorText.keyImportMessage(error))
                    .accessibilityIdentifier("hostEditor.keyProblem")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if error == .rsaNotSupported || error.isUnsupportedKeyType {
                Button("Use This Device’s Key Instead") { model.useDeviceKeyInstead() }
                    .accessibilityIdentifier("hostEditor.useDeviceKey")
            }
        case .empty, .valid:
            EmptyView()
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
                            .foregroundStyle(.secondaryText)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .accessibilityIdentifier("hostEditor.result")
            case .connected(let check):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected · herdr \(check.herdrVersion)")
                        Text(check.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondaryText)
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
            case .restartServerRequired:
                // Windows 沒有 live handoff:更新只換了執行檔。
                Label {
                    Text("herdr is updated. Restart the herdr server on this host to use the new version, then test the connection again.")
                } icon: {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
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
        case .windows: "Windows"
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

extension HostEditorModel.HostServiceCheck {
    /// 「3 agents · Read-only」
    var summary: String {
        let agents = String(localized: "\(agentCount) agents")
        return readOnly == true ? agents + " · " + String(localized: "Read-only") : agents
    }
}

private extension SSHKeyImportError {
    var isUnsupportedKeyType: Bool {
        if case .unsupportedKeyType = self { return true }
        return false
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
