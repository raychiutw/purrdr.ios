import PurrdrCore
import SwiftUI

/// 持有引導 model 的畫面:push 進來時建一次，父畫面重新計算 body 也不會換掉進行中的引導。
struct AddHostGuideScreen: View {
    @State private var model: AddHostGuideModel
    let onSaved: (HostConfiguration) -> Void
    let onCancel: () -> Void
    let onOpenEditor: (HostConfiguration.ConnectionMethod) -> Void

    init(
        make: () -> AddHostGuideModel, onSaved: @escaping (HostConfiguration) -> Void, onCancel: @escaping () -> Void,
        onOpenEditor: @escaping (HostConfiguration.ConnectionMethod) -> Void
    ) {
        _model = State(initialValue: make())
        self.onSaved = onSaved
        self.onCancel = onCancel
        self.onOpenEditor = onOpenEditor
    }

    var body: some View {
        AddHostGuideView(model: model, onSaved: onSaved, onCancel: onCancel, onOpenEditor: onOpenEditor)
    }
}

/// 新增主機引導(#341,版面「2 底部玻璃面板」,DESIGN.md「新增主機引導」):
/// 上方大圖示與問題，選項(玻璃膠囊)與主要按鈕在底部浮動的玻璃面板;步驟、指令、欄位是內容層，不用玻璃。
/// 一頁只問一件事，可返回與取消;每個指令可拷貝與分享到電腦。
struct AddHostGuideView: View {
    @Bindable var model: AddHostGuideModel
    let onSaved: (HostConfiguration) -> Void
    let onCancel: () -> Void
    /// 這個引導接不了的路徑(目前是原生 SSH 與 HTTPS):換成主機編輯頁。
    let onOpenEditor: (HostConfiguration.ConnectionMethod) -> Void
    @State private var expandedHelp: AddHostGuideModel.Field?
    @FocusState private var focus: AddHostGuideModel.Field?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                VStack(spacing: 8) {
                    Text(title)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("guide.title")
                    if let subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                }
                content
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { bottomPanel }
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .interactiveDismissDisabled()
        .onChange(of: model.handoff) { _, handoff in
            if case .editor(let method)? = handoff { onOpenEditor(method) }
        }
        // 進到測試連線那頁就開始測;失敗後按「再試一次」。
        .task(id: model.step) {
            if model.step == .test, model.phase == .editing { await model.testConnection() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guide")
    }

    // MARK: - 導覽

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if model.canGoBack {
                Button("Back", systemImage: "chevron.backward") { back() }
                    .accessibilityIdentifier("guide.back")
            } else {
                Button("Cancel") { cancel() }
                    .accessibilityIdentifier("guide.cancel")
            }
        }
        ToolbarItem(placement: .principal) {
            let progress = model.progress
            Text("Step \(progress.position) of \(progress.total)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondaryText)
                .accessibilityIdentifier("guide.progress")
        }
        ToolbarItem(placement: .confirmationAction) {
            if model.canGoBack {
                Button("Cancel") { cancel() }
                    .accessibilityIdentifier("guide.cancel")
            }
        }
    }

    private func back() {
        focus = nil
        expandedHelp = nil
        model.back()
    }

    private func cancel() {
        model.cancel()
        onCancel()
    }

    // MARK: - 標題與圖示

    private var hero: some View {
        Image(systemName: heroSymbol)
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: 84, height: 84)
            .background(.fill.tertiary, in: .rect(cornerRadius: 26))
            .padding(.top, 12)
            .accessibilityHidden(true)
    }

    private var heroSymbol: String {
        switch model.step {
        case .kind: "link"
        case .system: "desktopcomputer"
        case .sshMethod: "lock.shield"
        case .enable: "terminal"
        case .details: "text.cursor"
        case .test: "antenna.radiowaves.left.and.right"
        case .finished: "checkmark.circle.fill"
        }
    }

    private var title: LocalizedStringKey {
        switch model.step {
        case .kind: "How do you want to connect to your computer?"
        case .system: "What kind of computer is it?"
        case .sshMethod: model.system == .windows ? "Windows uses OpenSSH" : "Pick a kind of SSH"
        case .enable: "Let the computer accept connections"
        case .details: "Which computer and which account?"
        case .test: testTitle
        case .finished: "You’re connected"
        }
    }

    private var testTitle: LocalizedStringKey {
        switch model.phase {
        case .confirmHostKey: "First time connecting to this computer"
        case .failed, .needsUpdate, .restartServerRequired: "Couldn’t connect"
        case .hostKeyChanged: "This computer looks different"
        case .tested, .connected: "Connected"
        default: "Connecting…"
        }
    }

    private var subtitle: LocalizedStringKey? {
        switch model.step {
        case .system: "Pick the computer your agents run on."
        case .sshMethod where model.system == .windows: "It’s built into Windows. You only need to turn it on."
        case .finished: "\(model.savedHost?.name ?? "") was added."
        default: nil
        }
    }

    // MARK: - 內容層(不用玻璃)

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .enable:
            instructions(model.enableInstructions)
        case .details:
            detailsFields
        case .test:
            testContent
        case .kind, .system, .sshMethod, .finished:
            EmptyView()
        }
    }

    private func instructions(_ steps: [AddHostGuideInstruction]) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, instruction in
                HStack(alignment: .top, spacing: 12) {
                    Text(verbatim: "\(index + 1)")
                        .font(.footnote.bold())
                        .foregroundStyle(.onAccent)
                        .frame(width: 26, height: 26)
                        .background(.tint, in: .circle)
                        .accessibilityHidden(true)
                    InstructionView(instruction: instruction)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 18))
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var detailsFields: some View {
        VStack(spacing: 12) {
            detailField(.address, label: "Computer name or IP", text: $model.address, prompt: "studio-mac", numeric: false)
            detailField(.port, label: "Port", text: $model.port, prompt: "22", numeric: true)
            detailField(.username, label: "Account", text: $model.username, prompt: "ray", numeric: false)
        }
    }

    private func detailField(
        _ field: AddHostGuideModel.Field, label: LocalizedStringKey, text: Binding<String>, prompt: String, numeric: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondaryText)
            TextField(label, text: text, prompt: Text(verbatim: prompt))
                .font(.title3)
                #if os(iOS)
                .keyboardType(numeric ? .numberPad : .asciiCapable)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .submitLabel(.next)
                .accessibilityIdentifier("guide.field.\(identifier(field))")
            if let help = model.help(for: field) {
                DisclosureGroup(
                    isExpanded: Binding(get: { expandedHelp == field }, set: { expandedHelp = $0 ? field : nil })
                ) {
                    InstructionView(instruction: help)
                        .padding(.top, 6)
                } label: {
                    Text("How do I find this?").foregroundStyle(.primary)
                }
                .font(.footnote)
                .accessibilityIdentifier("guide.help.\(identifier(field))")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
    }

    private func identifier(_ field: AddHostGuideModel.Field) -> String {
        switch field {
        case .address: "address"
        case .port: "port"
        case .username: "username"
        }
    }

    @ViewBuilder
    private var testContent: some View {
        switch model.phase {
        case .confirmHostKey(let fingerprint):
            VStack(alignment: .leading, spacing: 12) {
                Text("Purrdr will warn you if this computer’s identity ever changes.")
                    .font(.body)
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: fingerprint.description)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("guide.fingerprint")
                        Text("To compare, run ssh-keygen -lf on a host key file on that computer.")
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                    }
                    .padding(.top, 6)
                }
                .font(.footnote)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 18))
        case .hostKeyChanged:
            ErrorLabel(String(localized: "This computer’s identity is different from the one you trusted before. Someone may be intercepting the connection. Don’t continue unless you changed this computer yourself."))
                .accessibilityIdentifier("guide.result")
        case .failed(let message):
            ErrorLabel(message)
                .accessibilityIdentifier("guide.result")
        case .needsUpdate:
            ErrorLabel(String(localized: "herdr on that computer is too old. Update herdr there, then try again."))
                .accessibilityIdentifier("guide.result")
        case .restartServerRequired:
            ErrorLabel(String(localized: "herdr is updated. Restart the herdr server on that computer, then try again."))
                .accessibilityIdentifier("guide.result")
        case .tested(let report):
            Text("herdr \(report.herdrVersion.description) · \(report.operatingSystem.displayName)")
                .font(.footnote)
                .foregroundStyle(.secondaryText)
                .accessibilityIdentifier("guide.result")
        case .connected:
            EmptyView()
        default:
            ProgressView()
                .controlSize(.large)
                .padding(.top, 24)
                .accessibilityIdentifier("guide.testing")
        }
    }

    // MARK: - 底部玻璃面板(控制層)

    @ViewBuilder
    private var bottomPanel: some View {
        GlassEffectContainer {
            // 大字級時選項比螢幕高:放得下就照原樣,放不下改成面板內捲動。
            ViewThatFits(in: .vertical) {
                panelStack
                ScrollView { panelStack }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 360)
            }
            .padding(14)
            .frame(maxWidth: 560)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("guide.panel")
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
        }
    }

    private var panelStack: some View {
        VStack(spacing: 10) { panelContent }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch model.step {
        case .kind:
            option("ssh", "SSH", detail: "Recommended · works on most computers", symbol: "terminal") { model.choose(.ssh) }
            option(
                "https", "HTTPS (Host Service)", detail: "Install the Purrdr host service for send-when-done and stuck alerts",
                symbol: "lock.shield") { model.choose(.https) }
        case .system:
            option("macOS", "Mac", symbol: "laptopcomputer") { model.choose(.macOS) }
            option("linux", "Linux", symbol: "server.rack") { model.choose(.linux) }
            option("windows", "Windows", symbol: "pc") { model.choose(.windows) }
        case .sshMethod:
            ForEach(model.availableSSHMethods, id: \.self) { method in
                switch method {
                case .tailscale:
                    option(
                        "tailscale", "Tailscale SSH", detail: "Recommended · no password or key, works anywhere",
                        symbol: "sparkles") { model.choose(.tailscale) }
                case .native:
                    option(
                        "native", model.system == .windows ? "OpenSSH" : "Built-in SSH",
                        detail: "Sign in with an account and password or key", symbol: "terminal") { model.choose(.native) }
                }
            }
        case .enable:
            primary("I’ve Turned It On", id: "guide.next", enabled: model.canAdvance) { model.advance() }
        case .details:
            primary("Next", id: "guide.next", enabled: model.canAdvance) {
                focus = nil
                model.advance()
            }
        case .test:
            testPanel
        case .finished:
            primary("Done", id: "guide.done", enabled: true) {
                if let host = model.savedHost { onSaved(host) }
            }
        }
    }

    @ViewBuilder
    private var testPanel: some View {
        switch model.phase {
        case .confirmHostKey:
            Text("Trust this computer?")
                .font(.headline)
            primary("Trust", id: "guide.trust", enabled: true) { Task { await model.trustHostKey() } }
            Button("Cancel") { back() }
                .buttonStyle(.glass)
                .accessibilityIdentifier("guide.trustCancel")
        case .tested, .connected:
            primary("Add This Computer", id: "guide.save", enabled: true) { _ = model.save() }
        case .hostKeyChanged:
            primary("Go Back", id: "guide.back.changed", enabled: true) { back() }
        case .failed, .needsUpdate, .restartServerRequired:
            primary("Try Again", id: "guide.retry", enabled: true) { Task { await model.testConnection() } }
        default:
            primary("Connecting…", id: "guide.connecting", enabled: false) {}
        }
    }

    private func primary(
        _ title: LocalizedStringKey, id: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .filledProminentButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }

    /// 玻璃面板裡的選項:圓角到底的膠囊，點了就進下一頁。
    private func option(
        _ id: String, _ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, symbol: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.fill.tertiary, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.55), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("guide.option.\(id)")
    }
}

/// 一步的說明:一句話，可帶指令(拷貝、分享到電腦)或連結(開啟、分享到電腦)。
private struct InstructionView: View {
    let instruction: AddHostGuideInstruction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(instruction.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let command = instruction.command {
                Text(verbatim: command)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("guide.command")
                HStack(spacing: 8) {
                    Button("Copy", systemImage: "document.on.document") { Clipboard.copy(command) }
                        .accessibilityLabel(Text("Copy \(command)"))
                        .accessibilityIdentifier("guide.copy")
                    ShareLink(item: command) {
                        Label("Share to Computer", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("guide.share")
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .controlSize(.small)
            }
            if let link = instruction.link {
                HStack(spacing: 8) {
                    Link(destination: link) {
                        Label(instruction.linkTitle ?? String(localized: "Open"), systemImage: "safari")
                    }
                    .accessibilityIdentifier("guide.link")
                    ShareLink(item: link) {
                        Label("Share to Computer", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("guide.shareLink")
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .controlSize(.small)
            }
        }
    }
}
