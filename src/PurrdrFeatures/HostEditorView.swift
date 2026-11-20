import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 新增／編輯主機(行為規格 F1.2、§8.2、§8.3;HIG 檢核 20.3)。
///
/// 儲存前必須通過連線測試;第一次連線以 alert 確認 host key 指紋;herdr 過舊時確認後更新。
/// OpenSSH 主機可用這支裝置的金鑰、匯入的私鑰或密碼登入;公鑰與加入指令在同一個 sheet 內 push。
/// 順序(#250):名稱 → 圖示 → 連線方式(卡片單選)→ 選了才出現該方式的欄位;輸入值一律靠左。
/// HTTPS 主機填位址、Port 與配對碼;配對碼旁的掃描鈕開 app 內相機掃主機配對指令的 QR code。
struct HostEditorView: View {
    @State private var model: HostEditorModel
    @State private var confirmingDiscard = false
    @State private var scanning = false
    @State private var showsAdvanced = false
    @Environment(\.pairingCodeScanSource) private var scanSource
    let onSaved: (HostConfiguration) -> Void
    let onCancel: () -> Void
    /// 只改了圖示就儲存：主機設定沒變，不必重新連線。
    let onIconSaved: () -> Void
    /// 已存主機的主機設定(#274):主機主題、You should know、Codex 啟動器，放在主機頁最下方;新增主機時沒有。
    let hostSettings: HostSettings?
    /// 已配對 HTTPS 主機的主機服務與已配對裝置(#290、#291),在主機頁下方;可以下拉重新整理。
    @State private var hostStatus: HostStatusModels?

    /// - Parameters:
    ///   - hostStatusConnection: 已配對 HTTPS 主機的連線。
    ///   - onRemoveHost: 已配對裝置「這支裝置」那列走移除主機的流程。
    init(
        model: HostEditorModel, hostSettings: HostSettings? = nil, hostStatusConnection: (any HostConnection)? = nil,
        onRemoveHost: (@MainActor () -> Void)? = nil,
        onSaved: @escaping (HostConfiguration) -> Void,
        onCancel: @escaping () -> Void, onIconSaved: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        // 有自訂 herdr 設定的主機一打開就看得到。
        _showsAdvanced = State(initialValue: !(model.herdrPath.isEmpty && model.herdrSession.isEmpty))
        self.onSaved = onSaved
        self.onCancel = onCancel
        self.onIconSaved = onIconSaved
        self.hostSettings = hostSettings
        _hostStatus = State(initialValue: hostStatusConnection.map { HostStatusModels(connection: $0, removeHost: onRemoveHost) })
    }

    /// 主機服務與已配對裝置的下拉重新整理;沒有這兩個區塊時不能下拉。
    private var refreshHostStatus: (@Sendable () async -> Void)? {
        guard let hostStatus else { return nil }
        return { await hostStatus.refresh() }
    }

    var body: some View {
        Form {
            Section {
                field("Name", text: $model.name, prompt: "Studio Mac", identifier: "name")
            } header: {
                Text("Host")
                    .foregroundStyle(.secondaryText)
            }

            Section {
                HostIconGrid(selection: $model.icon)
            } header: {
                Text("Icon")
                    .foregroundStyle(.secondaryText)
            }

            connectionMethodSection

            if let method = model.connectionMethod {
                connectionSection(method)
                if model.connectionFields.contains(.pairingCode) {
                    pairingSection
                }
                if model.connectionFields.contains(.signIn) {
                    signInSection
                }
                if model.connectionFields.contains(.advanced) {
                    advancedSection
                }

                Section {
                    testStatus
                } footer: {
                    Text("Purrdr tests the connection before saving the host.")
                        .foregroundStyle(.secondaryText)
                }
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

            if let hostSettings {
                HostThemeSettingsSection(model: hostSettings.hostTheme)
                YouShouldKnowSettingsSection(model: hostSettings.youShouldKnow)
                CodexLauncherSection(model: hostSettings.codexLauncher)
            }

            if let hostStatus {
                HostStatusSections(models: hostStatus)
            }
        }
        .refreshable(refreshHostStatus)
        .modifier(PairedDevicesDialogs(model: hostStatus?.pairedDevices))
        .sheet(isPresented: $scanning) {
            PairingCodeScannerView(source: scanSource) { model.applyScannedCode($0) }
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
                    if model.hasChanges { confirmingDiscard = true } else { cancel() }
                }
                .confirmationDialog("Discard your changes to this host?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { cancel() }
                    Button("Keep Editing", role: .cancel) {}
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let changesOnlyIcon = model.changesOnlyIcon
                    guard let host = model.save() else { return }
                    if changesOnlyIcon { onIconSaved() } else { onSaved(host) }
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
        .alert("Add This Device’s Key?", isPresented: presenting(\.isConfirmingKeyInstall)) {
            Button("Add Key") { Task { await model.confirmKeyInstall() } }
            Button("Cancel", role: .cancel) { model.dismissPrompt() }
        } message: {
            Text("Purrdr signs in to \(model.username)@\(model.address) once with this password and adds this device’s public key to ~/.ssh/authorized_keys (administrators_authorized_keys for a Windows administrator). After that it signs in with the key. The password isn’t saved.")
        }
        .alert("Update herdr?", isPresented: presenting(\.isOutdated)) {
            if model.canUpdateHerdr {
                Button("Update") { Task { await model.updateHerdr() } }
                Button("Cancel", role: .cancel) { model.dismissPrompt() }
            } else {
                Button("OK", role: .cancel) { model.dismissPrompt() }
            }
        } message: {
            if case .needsUpdate(let version) = model.phase {
                if model.canUpdateHerdr {
                    Text("This host has herdr \(version.description). Purrdr needs \(HerdrVersion.minimumSupported.description) or later. Purrdr will update herdr as \(model.username)@\(model.address).")
                } else {
                    Text("This host has herdr \(version.description). Purrdr needs \(HerdrVersion.minimumSupported.description) or later. Update herdr on the host, then test the connection again.")
                }
            }
        }
    }

    /// 取消：配對拿到但沒存下的權杖請主機撤銷。
    private func cancel() {
        model.discardUnsavedPairing()
        onCancel()
    }

    // MARK: - 連線方式(#250)

    /// 三列攤開單選(#313:同「設定」app 的勾選列，選中的列尾打勾),各附一句說明;選了才出現下面的連線欄位。
    private var connectionMethodSection: some View {
        Section {
            ForEach(HostConfiguration.ConnectionMethod.editorOrder, id: \.self) { method in
                methodCard(method)
            }
        } header: {
            Text("Connection")
                .foregroundStyle(.secondaryText)
        } footer: {
            if model.connectionMethod == nil {
                Text("Choose how Purrdr connects, then fill in the connection details.")
                    .foregroundStyle(.secondaryText)
            }
        }
    }

    private func methodCard(_ method: HostConfiguration.ConnectionMethod) -> some View {
        let isSelected = model.connectionMethod == method
        return Button {
            model.connectionMethod = method
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: method.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(method.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("hostEditor.method.\(method.rawValue)")
    }

    /// 位址、Port,SSH 另有帳號。
    private func connectionSection(_ method: HostConfiguration.ConnectionMethod) -> some View {
        Section {
            field(
                "Address", text: $model.address, prompt: method.usesHostService ? "my-mac.tailnet.ts.net" : "my-mac or 100.64.0.1",
                identifier: "address")
            .addressKeyboard()
            field("Port", text: $model.port, prompt: method.usesHostService ? "443" : "22", identifier: "port")
                .numberKeyboard()
            if model.connectionFields.contains(.username) {
                field("User Name", text: $model.username, prompt: "Your user on that computer", identifier: "username")
            }
        } header: {
            Text("Connection Details")
                .foregroundStyle(.secondaryText)
        } footer: {
            connectionFooter(method)
                .foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private func connectionFooter(_ method: HostConfiguration.ConnectionMethod) -> some View {
        switch method {
        case .tailscaleSSH:
            Text("Tailscale checks who you are on your tailnet, so no key or password is needed.")
        case .openSSH:
            EmptyView()
        case .https:
            VStack(alignment: .leading, spacing: 8) {
                Text("Install the Purrdr host service on the host and run purrdr-host-service pair, then scan its QR code or enter the address, port, and pairing code it shows. Login Shell and Files aren’t available over HTTPS.")
                Link("How to Install the Host Service", destination: PurrdrLinks.hostServiceGuide)
                    .accessibilityIdentifier("hostEditor.hostServiceGuide")
            }
        }
    }

    /// 配對碼，右邊是掃描 QR code 的按鈕(裝置不支援時只能手動輸入)。
    private var pairingSection: some View {
        Section {
            HStack(spacing: 8) {
                field(
                    "Pairing Code", text: $model.pairingCode, prompt: model.needsPairingCode ? "K7QM-2XPA" : "Unchanged",
                    identifier: "pairingCode", uppercase: true)
                // 欄位也顯示成大寫：硬體鍵盤與貼上不受全大寫鍵盤影響。另一個交易才改，TextField 才會跟著更新。
                .onChange(of: model.pairingCode) { _, code in
                    let uppercased = code.uppercased()
                    if uppercased != code { model.pairingCode = uppercased }
                }
                if scanSource.isAvailable {
                    Button {
                        scanning = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Scan QR Code")
                    .accessibilityIdentifier("hostEditor.scanPairingCode")
                }
            }
        } header: {
            Text("Pairing")
                .foregroundStyle(.secondaryText)
        }
    }

    /// herdr 路徑與 Session 收在「進階」(HTTPS 的 herdr session 由主機服務決定)。
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                field("herdr Path", text: $model.herdrPath, prompt: "herdr", identifier: "herdrPath")
                field("Session", text: $model.herdrSession, prompt: "Default", identifier: "herdrSession")
            } label: {
                Text("Advanced")
            }
            .accessibilityIdentifier("hostEditor.advanced")
        } footer: {
            if showsAdvanced {
                Text("Leave Session blank unless this computer runs more than one herdr session.")
                    .foregroundStyle(.secondaryText)
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
            // 選項攤開成勾選列(#313,原型 agent-observer 第 2 版 A)。
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("hostEditor.signIn")
            switch model.authentication {
            case .deviceKey: deviceKeyRows
            case .importedKey: importedKeyRows
            case .password:
                LabeledContent("Password") {
                    SecureField("Password", text: $model.password, prompt: Text(model.hasStoredSecret ? "Unchanged" : "Required"))
                        .multilineTextAlignment(.leading)
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
            keyInstallRows(publicKey)
        } else if let problem = model.deviceKeyProblem {
            ErrorLabel(problem)
        } else {
            ProgressView()
                .task { await model.loadDeviceKey() }
        }
    }

    /// 用這台電腦的密碼加入公鑰(#285):密碼只用一次;失敗時仍可拷貝指令手動加入。
    @ViewBuilder
    private func keyInstallRows(_ publicKey: SSHPublicKey) -> some View {
        LabeledContent("Password") {
            SecureField("Password", text: $model.keyInstallPassword, prompt: Text("Password on that computer"))
                .multilineTextAlignment(.leading)
                .accessibilityIdentifier("hostEditor.keyInstallPassword")
        }
        if model.phase == .installingKey {
            HStack {
                ProgressView()
                Text("Adding the key to \(model.address)…")
            }
        } else {
            Button("Add Key Using Password") { model.requestKeyInstall() }
                .disabled(!model.canInstallDeviceKey)
                .accessibilityIdentifier("hostEditor.installKey")
        }
        if case .keyInstallFailed(let message) = model.phase {
            ErrorLabel(message)
                .accessibilityIdentifier("hostEditor.keyInstallResult")
            NavigationLink {
                DevicePublicKeyView(publicKey: publicKey, username: model.username)
            } label: {
                Label("Copy Command Instead", systemImage: "document.on.document")
            }
            .accessibilityIdentifier("hostEditor.keyInstallManual")
        } else if let outcome = model.keyInstallOutcome {
            Label {
                switch outcome {
                case .added: Text("Key added. Purrdr signs in with this device’s key.")
                case .alreadyPresent: Text("The key was already on the host.")
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            }
            .accessibilityIdentifier("hostEditor.keyInstallResult")
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
            ErrorLabel(HostErrorText.keyImportMessage(error))
                .accessibilityIdentifier("hostEditor.keyProblem")
            if error == .rsaNotSupported || error.isUnsupportedKeyType {
                Button("Use This Device’s Key Instead") { model.useDeviceKeyInstead() }
                    .accessibilityIdentifier("hostEditor.useDeviceKey")
            }
        case .empty, .valid:
            EmptyView()
        }
    }

    /// 連線測試成功的結果列(SSH 與 HTTPS 共用)。
    private func connectedRow(_ title: Text, summary: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                title
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        }
        .accessibilityIdentifier("hostEditor.result")
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
                connectedRow(
                    Text("Connected · herdr \(report.herdrVersion.description) · \(report.operatingSystem.displayName)"),
                    summary: report.summary)
            case .connected(let check):
                connectedRow(Text("Connected · herdr \(check.herdrVersion)"), summary: check.summary)
            case .failed(let message):
                ErrorLabel(message)
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

    /// `uppercase`:全大寫鍵盤(配對碼)。要設在 TextField 上：外層再設會被這裡的 `.plainTextInput()` 蓋掉。
    private func field(
        _ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, identifier: String, uppercase: Bool = false
    ) -> some View {
        LabeledContent(label) {
            // 輸入值靠左：靠右時尾端空白會被吃掉、看不見(#250)。
            let field = TextField(label, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.leading)
                .autocorrectionDisabled()
            Group {
                if uppercase {
                    field.uppercaseInput()
                } else {
                    field.plainTextInput()
                }
            }
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

    var isConfirmingKeyInstall: Bool { self == .confirmKeyInstall }
}

extension HostConfiguration.ConnectionMethod {
    /// 加入主機頁卡片的順序。
    static let editorOrder: [Self] = [.tailscaleSSH, .openSSH, .https]

    /// 產品名稱，不翻譯。
    var title: String {
        switch self {
        case .tailscaleSSH: "Tailscale SSH"
        case .openSSH: "OpenSSH"
        case .https: "HTTPS"
        }
    }

    /// 卡片上的一句說明。
    var summary: LocalizedStringKey {
        switch self {
        case .tailscaleSSH: "Tailscale confirms who you are. No password or key needed."
        case .openSSH: "Sign in to the host’s own SSH server with a key or password."
        case .https: "Pair with the Purrdr host service. Login Shell and Files aren’t available."
        }
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

    /// 配對碼是大寫字母(HIG TF-1);自動修正已由 `field` 關掉。
    func uppercaseInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.characters)
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
