import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 新增／編輯主機(行為規格 F1.2、§8.2、§8.3;HIG 檢核 20.3)。
///
/// 儲存前必須通過連線測試;第一次連線以 alert 確認 host key 指紋;herdr 過舊時確認後更新。
/// OpenSSH 主機可用這支裝置的金鑰(三步在同一頁)、匯入的私鑰或密碼登入。
/// 順序(#346):名稱與圖示(最上面)→ 連線方式(勾選列)→ 位址／Port／帳號 → 登入方式 → 詳細資訊 → 測試連線;輸入值一律靠左。
/// HTTPS 主機填位址、Port 與配對碼;配對碼旁的掃描鈕開 app 內相機掃主機配對指令的 QR code。
struct HostEditorView: View {
    @State private var model: HostEditorModel
    @State private var confirmingDiscard = false
    @State private var scanning = false
    @State private var showsAdvanced = false
    /// 鍵盤焦點所在的欄位(#312):return 依畫面順序往下，「完成」與捲動收起鍵盤。
    @FocusState private var focus: HostEditorModel.InputField?
    /// 私鑰欄在畫面上的位置(全域座標),拖動起點在裡面時不收鍵盤。
    @State private var privateKeyFrame = CGRect.null
    @Environment(\.pairingCodeScanSource) private var scanSource
    let onSaved: (HostConfiguration) -> Void
    let onCancel: () -> Void
    /// 只改了圖示就儲存：主機設定沒變，不必重新連線。
    let onIconSaved: () -> Void

    init(
        model: HostEditorModel,
        onSaved: @escaping (HostConfiguration) -> Void,
        onCancel: @escaping () -> Void, onIconSaved: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        // 有自訂 herdr 設定的主機一打開就看得到。
        _showsAdvanced = State(initialValue: model.detailsExpandedInitially)
        self.onSaved = onSaved
        self.onCancel = onCancel
        self.onIconSaved = onIconSaved
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                // 焦點移到的欄位(return 跳到下一個)捲到看得見的地方。
                .onChange(of: focus) { _, field in
                    guard let field else { return }
                    withAnimation { proxy.scrollTo(field) }
                }
        }
    }

    private var form: some View {
        Form {
            Section {
                field("Name", text: $model.name, prompt: "Studio Mac", identifier: "name", focus: .name)
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
            }

            if model.connectionMethod != nil {
                Section {
                    testStatus
                } footer: {
                    Text("Purrdr tests the connection before saving the host.")
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .appGroupedList()
        // 捲動表單就收起鍵盤(#312):`.interactively` 只在手指拖進鍵盤時才收，往下捲看下面的按鈕時鍵盤仍擋著。
        // 數字鍵盤與多行私鑰沒有能收鍵盤的 return,另有鍵盤上方的「完成」。
        .scrollDismissesKeyboard(.immediately)
        // 這個 Form(sheet 裡、有 refreshable)在 iOS 26 上 `.scrollDismissesKeyboard` 不起作用(UI 測試實測),
        // 所以垂直拖動時自己清掉焦點;最短距離避開點按。
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .global).onChanged { drag in
                guard focus != nil, abs(drag.translation.height) > abs(drag.translation.width) else { return }
                // 從私鑰欄(多行輸入)開始的拖動是在欄內捲動或選字，不收鍵盤(#312、#329)。
                guard !privateKeyFrame.contains(drag.startLocation) else { return }
                focus = nil
            })
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
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
                    .accessibilityIdentifier("hostEditor.keyboardDone")
            }
            #endif
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
                    // 只改名稱或圖示:主機設定沒變,不必重新連線。
                    let changesOnlyAppearance = model.changesOnlyAppearance
                    guard let host = model.save() else { return }
                    if changesOnlyAppearance { onIconSaved() } else { onSaved(host) }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("hostEditor.save")
            }
        }
        .sheet(isPresented: presenting(\.isConfirmingHostKey)) {
            if case .confirmHostKey(let fingerprint) = model.phase {
                HostTrustView(
                    address: model.address, fingerprint: fingerprint, operatingSystem: model.hostOperatingSystem,
                    trust: { Task { await model.trustPresentedHostKey() } }, cancel: { model.dismissPrompt() })
            }
        }
        // 指紋變了:只能停下來,沒有「信任新的」。要重新連,得刪掉這台主機再新增。
        .alert("This Host’s Identity Changed", isPresented: presenting(\.isHostKeyChanged)) {
            Button("OK", role: .cancel) { model.dismissPrompt() }
        } message: {
            if case .hostKeyChanged(let presented, let pinned) = model.phase {
                Text("Purrdr stopped because this host no longer looks like the one you trusted before. This happens if it was reinstalled or reset, and also if someone is intercepting the connection. If you didn’t reinstall or reset it, don’t connect.\n\nIf you did, delete this host and add it again.\n\nKey now:\n\(presented.description)\n\nKey you trusted:\n\(pinned.description)")
            }
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
                    Text("herdr on this host is \(version.description); Purrdr needs \(HerdrVersion.minimumSupported.description) or newer. Purrdr will update it, signed in as \(model.username)@\(model.address).")
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
                identifier: "address", focus: .address)
            .addressKeyboard()
            field("Port", text: $model.port, prompt: method.usesHostService ? "443" : "22", identifier: "port", focus: .port)
                .numberKeyboard()
            if model.connectionFields.contains(.username) {
                field("Account Name", text: $model.username, prompt: "Your account on that computer", identifier: "username", focus: .username)
                    .usernameContent()
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
            Text("Tailscale knows it’s you, so no password or key is needed.")
        case .openSSH:
            EmptyView()
        case .https:
            VStack(alignment: .leading, spacing: 8) {
                Text("On the host, install the Purrdr host service and run the command below. Then scan the QR code it shows. Login Shell and Files aren’t available this way.")
                InstructionView(instruction: AddHostGuideInstruction(text: String(localized: "Run this on the host:"), command: HostEditorModel.hostServicePairCommand))
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
                    identifier: "pairingCode", focus: .pairingCode, uppercase: true)
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

    /// herdr 路徑與 Session 收在「詳細資訊」(與主機指紋同一組)(HTTPS 的 herdr session 由主機服務決定)。
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                if let fingerprint = model.hostKeyFingerprint {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Host Key")
                            .font(.subheadline.weight(.semibold))
                        Text(fingerprint.description)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("hostEditor.fingerprint")
                        InstructionView(
                            instruction: AddHostGuideInstruction(
                                text: String(localized: "To compare, run this on that computer:"),
                                command: HostKeyFingerprint.compareCommand(on: model.hostOperatingSystem)))
                    }
                }
                field("herdr Path", text: $model.herdrPath, prompt: "herdr", identifier: "herdrPath", focus: .herdrPath)
                field("Session", text: $model.herdrSession, prompt: "Default", identifier: "herdrSession", focus: .herdrSession)
            } label: {
                Text("Details")
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
                        .existingPasswordContent()
                        .focusOrder(.password, focus: $focus, next: nextField(after: .password))
                        .accessibilityIdentifier("hostEditor.password")
                }
                .id(HostEditorModel.InputField.password)
            }
        } header: {
            Text("Sign In")
                .foregroundStyle(.secondaryText)
        } footer: {
            Group {
                switch model.authentication {
                case .deviceKey:
                    Text("The key stays on this device and never leaves it. Follow the steps above to let this device in.")
                case .importedKey:
                    Text("Paste the private key file you use to sign in to that computer. Keys with a passphrase aren’t supported. The key stays on this device.")
                case .password:
                    Text("The password stays on this device.")
                }
            }
            .foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private var deviceKeyRows: some View {
        if let publicKey = model.devicePublicKey {
            // 金鑰三步在同一頁(#346):打開終端機、貼上指令、回來測試連線。
            ForEach(Array(model.deviceKeySteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text(verbatim: "\(index + 1)")
                        .font(.footnote.bold())
                        .foregroundStyle(.onProminentFill)
                        .frame(width: 26, height: 26)
                        .background(.prominentFill, in: .circle)
                        .accessibilityHidden(true)
                    InstructionView(instruction: step)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("hostEditor.keyStep.\(index + 1)")
            }
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
            ErrorLabel(problem, area: "HostEditorView")
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
                    Text("Private key, \(model.privateKeyText.split(whereSeparator: \.isNewline).count) lines")
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
                    // 多行輸入：return 是換行，收鍵盤靠「完成」或捲動。
                    .focused($focus, equals: .privateKey)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { privateKeyFrame = $0 }
                    .accessibilityLabel("Private Key")
                    .accessibilityIdentifier("hostEditor.privateKey")
                if model.privateKeyText.isEmpty && model.hasStoredSecret {
                    Text("Leave blank to keep the saved key.")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                }
            }
            .id(HostEditorModel.InputField.privateKey)
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
            ErrorLabel(HostErrorText.keyImportMessage(error), area: "HostEditorView")
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
                VStack(alignment: .leading, spacing: 8) {
                    ErrorLabel(message, area: "HostEditorView")
                        .accessibilityIdentifier("hostEditor.result")
                    if let details = model.failureDetails {
                    DisclosureGroup("Details") {
                        Text(verbatim: details)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("hostEditor.details")
                    }
                    .font(.footnote)
                }
                }
            case .restartServerRequired:
                // Windows 沒有 live handoff:更新只換了執行檔。
                Label {
                    Text("herdr is updated. Restart herdr on this host to use the new version, then test the connection again.")
                } icon: {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                }
                .accessibilityIdentifier("hostEditor.result")
            default:
                EmptyView()
            }
        }
    }

    /// 單行欄位按 return 要移到的欄位;`nil` 收起鍵盤。
    private func nextField(after field: HostEditorModel.InputField) -> HostEditorModel.InputField? {
        model.inputField(after: field, showsAdvanced: showsAdvanced)
    }

    /// `uppercase`:全大寫鍵盤(配對碼)。要設在 TextField 上：外層再設會被這裡的 `.plainTextInput()` 蓋掉。
    private func field(
        _ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, identifier: String,
        focus inputField: HostEditorModel.InputField, uppercase: Bool = false
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
            .focusOrder(inputField, focus: $focus, next: nextField(after: inputField))
            .accessibilityIdentifier("hostEditor.\(identifier)")
        }
        .id(inputField)
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

extension HostConfiguration.ConnectionMethod {
    /// 加入主機頁卡片的順序。
    static let editorOrder: [Self] = [.tailscaleSSH, .openSSH, .https]

    /// 畫面上的名稱，不翻譯(OpenSSH 對一般使用者太技術，稱「SSH」,#477;內部值 `openSSH` 不變)。
    var title: String {
        switch self {
        case .tailscaleSSH: "Tailscale SSH"
        case .openSSH: "SSH"
        case .https: "HTTPS"
        }
    }

    /// 卡片上的一句說明。
    var summary: LocalizedStringKey {
        switch self {
        case .tailscaleSSH: "Tailscale confirms who you are. No password or key needed."
        case .openSSH: "Sign in to the host with a password or key."
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

extension SSHKeyImportError {
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

    /// 主機上既有的密碼：不跳「建議強密碼」(#312)。
    func existingPasswordContent() -> some View {
        #if os(iOS)
        textContentType(.password)
        #else
        self
        #endif
    }

    /// 帳號欄標成使用者名稱，密碼自動填入才配得上對。
    func usernameContent() -> some View {
        #if os(iOS)
        textContentType(.username)
        #else
        self
        #endif
    }

    /// 單行欄位的焦點與 return:有下一個欄位就移過去(鍵上寫「下一個」),最後一個收起鍵盤(「完成」)。
    func focusOrder(
        _ field: HostEditorModel.InputField, focus: FocusState<HostEditorModel.InputField?>.Binding,
        next: HostEditorModel.InputField?
    ) -> some View {
        focused(focus, equals: field)
            .submitLabel(next == nil ? .done : .next)
            .onSubmit { focus.wrappedValue = next }
    }

    func plainTextInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
