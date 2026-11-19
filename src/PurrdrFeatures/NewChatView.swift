import PurrdrCore
import PurrdrSSH
import SwiftUI

/// 新增對話(行為規格 F3.1;#18):選取中主機上的資料夾、名稱、agent、權限模式。
///
/// 以 sheet 開啟;資料夾瀏覽在同一個 sheet 內 push(HIG 檢核清單 20.3「多步驟在同一個 sheet 內 push」)。
/// Cancel 在左、Start 在右。開始中不能滑掉 sheet(主機上正在建立 workspace)。
public struct NewChatView: View {
    @Bindable var model: NewChatModel
    /// 標題列中間的主機挑選鈕(#245)。
    let hostPicker: HostPickerModel?
    let onCancel: () -> Void
    let onStarted: (CreatedWorkspace) -> Void

    public init(
        model: NewChatModel, hostPicker: HostPickerModel? = nil, onCancel: @escaping () -> Void,
        onStarted: @escaping (CreatedWorkspace) -> Void
    ) {
        self.model = model
        self.hostPicker = hostPicker
        self.onCancel = onCancel
        self.onStarted = onStarted
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder", text: $model.folder, prompt: Text(verbatim: "~/projects/app"))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .accessibilityIdentifier("newChat.folder")
                    NavigationLink {
                        FolderPickerView(model: model.makeFolderPicker()) { model.choose($0) }
                    } label: {
                        Label("Choose Folder on Host", systemImage: "folder")
                    }
                    .accessibilityIdentifier("newChat.chooseFolder")
                } header: {
                    Text("Folder")
                        .foregroundStyle(.secondaryText)
                } footer: {
                    Text("The agent starts in this folder on the host, in a new workspace.")
                        .foregroundStyle(.secondaryText)
                }

                Section {
                    TextField("Name", text: $model.name, prompt: Text("Optional. Uses the folder name."))
                        .accessibilityIdentifier("newChat.name")
                } header: {
                    Text("Name")
                        .foregroundStyle(.secondaryText)
                }

                Section {
                    Picker("Agent", selection: $model.agent) {
                        ForEach(NewChatAgent.allCases, id: \.self) { agent in
                            Text(verbatim: agent.displayName).tag(agent)
                        }
                    }
                    .accessibilityIdentifier("newChat.agent")
                    if model.showsPermissionMode {
                        Picker("Permissions", selection: $model.permissionMode) {
                            ForEach(ClaudePermissionMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .accessibilityIdentifier("newChat.permissionMode")
                    }
                } footer: {
                    Group {
                        agentFooter
                    }
                    .foregroundStyle(.secondaryText)
                }

                if let error = model.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.errorText)
                            .accessibilityIdentifier("newChat.error")
                    }
                }
            }
            .accessibilityIdentifier("sheet.newChat")
            .navigationTitle("New Chat")
            #if os(iOS)
            // 有主機挑選鈕時它佔標題列中間，「新增聊天」改成大標題放在下面(原型)。
            .navigationBarTitleDisplayMode(hostPicker == nil ? .inline : .large)
            #endif
            .interactiveDismissDisabled(model.isStarting)
            .toolbar {
                if let hostPicker {
                    ToolbarItem(placement: .principal) {
                        HostPickerButton(model: hostPicker, identifier: "newChat.host")
                            .disabled(model.isStarting)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(model.isStarting)
                        .accessibilityIdentifier("newChat.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isStarting {
                        ProgressView()
                            .accessibilityLabel(Text("Starting…"))
                            .accessibilityIdentifier("newChat.starting")
                    } else {
                        Button("Start", action: start)
                            .disabled(!model.canStart)
                            .accessibilityIdentifier("newChat.start")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var agentFooter: some View {
        switch model.agent {
        case .claude:
            Text(model.permissionMode.footer)
        case .codex:
            Text("Codex reports its session after you send the first message.")
        default:
            Text("The agent uses its own settings on the host.")
        }
    }

    private func start() {
        Task {
            if let created = await model.start() { onStarted(created) }
        }
    }
}

/// 新增對話的資料夾瀏覽(行為規格 F3.3):只列子資料夾;錯誤與空資料夾分開顯示。
struct FolderPickerView: View {
    let model: FolderPickerModel
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .navigationTitle("Choose Folder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Enclosing Folder", systemImage: "arrow.up") { Task { await model.goUp() } }
                        .disabled(!model.canGoUp)
                        .accessibilityIdentifier("folderPicker.up")
                }
                ToolbarItem(placement: Self.usePlacement) {
                    Button("Use This Folder") {
                        guard let path = model.chosenPath else { return }
                        onChoose(path)
                        dismiss()
                    }
                    .filledGlassProminentButtonStyle()
                    .disabled(model.chosenPath == nil)
                    .accessibilityIdentifier("folderPicker.use")
                }
            }
            .task { await model.load() }
    }

    #if os(iOS)
    private static let usePlacement = ToolbarItemPlacement.bottomBar
    #else
    private static let usePlacement = ToolbarItemPlacement.automatic
    #endif

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading folders…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("folderPicker.loading")
        case .failed(let message):
            ContentUnavailableView {
                Label("Can’t Open Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
                    .accessibilityIdentifier("folderPicker.retry")
            }
            .accessibilityIdentifier("folderPicker.error")
        case .loaded(let listing):
            List {
                Section {
                    if listing.folders.isEmpty {
                        Text("No folders inside this one. You can still use it.")
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("folderPicker.empty")
                    }
                    ForEach(listing.folders, id: \.self) { name in
                        Button {
                            Task { await model.open(name) }
                        } label: {
                            Label {
                                Text(verbatim: name).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                        .accessibilityIdentifier("folderPicker.row.\(name)")
                    }
                } header: {
                    Text(verbatim: listing.path)
                        .font(.footnote.monospaced())
                        .textCase(nil)
                        .accessibilityIdentifier("folderPicker.path")
                        .foregroundStyle(.secondaryText)
                }
            }
            .accessibilityIdentifier("folderPicker.list")
        }
    }
}

extension NewChatAgent {
    /// 產品名稱，不翻譯。
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        case .agy: "Antigravity"
        case .pi: "Pi"
        case .omp: "OMP"
        }
    }
}

extension ClaudePermissionMode {
    var title: LocalizedStringKey {
        switch self {
        case .agentDefault: "Claude Code’s Settings"
        case .manual: "Ask Every Time"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan Only"
        case .auto: "Auto"
        case .bypassPermissions: "Full Access"
        }
    }

    var footer: LocalizedStringKey {
        switch self {
        case .agentDefault: "Claude Code uses the permission settings it already has on this host."
        case .manual: "Claude Code asks before every tool it uses."
        case .acceptEdits: "Claude Code edits files without asking, and asks before running commands."
        case .plan: "Claude Code only plans. It doesn’t edit files or run commands."
        case .auto: "Claude Code decides which actions are safe to run without asking."
        case .bypassPermissions: "Claude Code runs commands and edits files without ever asking. Use this only in folders you trust."
        }
    }
}
