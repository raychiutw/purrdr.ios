import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH
import SwiftUI

/// 新增對話(#272,原型 purrdr-screens 定案版):標題列中間是主機挑選鈕，下面是 Agent(攤開的勾選列,#313)、資料夾、第一則訊息，
/// 最下方「開始」。名稱由 herdr 用資料夾名，權限沿用 agent 自己的設定。
///
/// 以 sheet 開啟;資料夾瀏覽在同一個 sheet 內 push(HIG 檢核清單 20.3「多步驟在同一個 sheet 內 push」)。
/// 開始中不能滑掉 sheet(主機上正在建立 workspace)。
public struct NewChatView: View {
    @Bindable var model: NewChatModel
    /// 標題列中間的主機挑選鈕(#245)。
    let hostPicker: HostPickerModel?
    let onCancel: () -> Void
    /// 開始了：新 workspace 與沒送出的第一則訊息(agent 停在啟動問題時)。
    let onStarted: (CreatedWorkspace, String?) -> Void

    public init(
        model: NewChatModel, hostPicker: HostPickerModel? = nil, onCancel: @escaping () -> Void,
        onStarted: @escaping (CreatedWorkspace, String?) -> Void
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
                    Picker("Agent", selection: $model.agent) {
                        ForEach(model.availableAgents, id: \.self) { agent in
                            Text(verbatim: AgentCatalog.profile(for: agent).presentation.displayName ?? agent.canonicalName).tag(agent)
                        }
                    }
                    // 選項攤開成勾選列(#313)。
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("newChat.agent")
                } header: {
                    Text("Agent")
                        .foregroundStyle(.secondaryText)
                } footer: {
                    if model.availableAgents.isEmpty {
                        Text("No Agents are turned on for this host. Open the Hosts tab, then Agent, to turn one on.")
                            .accessibilityIdentifier("newChat.noAgents")
                    }
                }

                Section {
                    TextField("Folder", text: $model.folder, prompt: Text(verbatim: model.canBrowseFolders ? "~/projects/app" : "/Users/you/projects/app"))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .accessibilityIdentifier("newChat.folder")
                    if model.canBrowseFolders {
                        NavigationLink {
                            FolderPickerView(model: model.makeFolderPicker()) { model.choose($0) }
                        } label: {
                            Label("Choose Folder on Host", systemImage: "folder")
                        }
                        .accessibilityIdentifier("newChat.chooseFolder")
                    }
                } header: {
                    Text("Folder")
                        .foregroundStyle(.secondaryText)
                } footer: {
                    if !model.canBrowseFolders {
                        // HTTPS 主機沒有資料夾瀏覽(#287)。
                        Text("Type the folder’s location on the host.")
                            .accessibilityIdentifier("newChat.fullPathHint")
                    }
                }

                sessionsSection

                Section {
                    TextField("Workspace Name", text: $model.workspaceName, prompt: Text("Optional"))
                        .accessibilityIdentifier("newChat.workspaceName")
                    TextField("Tab Name", text: $model.tabName, prompt: Text("Optional"))
                        .accessibilityIdentifier("newChat.tabName")
                } header: {
                    Text("Names")
                        .foregroundStyle(.secondaryText)
                } footer: {
                    Text("Leave these empty to use the folder’s name.")
                }

                Section {
                    TextField(
                        "First Message", text: $model.message,
                        prompt: model.isResuming ? Text("Say what’s next…") : Text("What should the agent do?"), axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("newChat.message")
                } header: {
                    Text(model.isResuming ? "Message" : "First Message")
                        .foregroundStyle(.secondaryText)
                }

                if let readOnlyReason = model.readOnlyReason {
                    Section {
                        Label(readOnlyReason, systemImage: "lock")
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("newChat.readOnly")
                    }
                }

                if let error = model.error {
                    Section {
                        ErrorLabel(error)
                            .accessibilityIdentifier("newChat.error")
                    }
                }

                Section {
                    Button(action: start) {
                        Group {
                            if model.isStarting {
                                ProgressView()
                                    .accessibilityLabel(Text("Starting…"))
                                    .accessibilityIdentifier("newChat.starting")
                            } else {
                                Text(model.isResuming ? "Resume" : "Start New Chat")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .filledProminentButtonStyle()
                    .disabled(!model.canStart)
                    .accessibilityIdentifier("newChat.start")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .appSheetList()
            .accessibilityIdentifier("sheet.newChat")
            .navigationTitle("New Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled(model.isStarting)
            .task(id: ObjectIdentifier(model)) { await model.loadAccess() }
            // 資料夾或 agent 變了就重讀過去的 session;打字時等一下再讀(#309)。
            .task(id: model.sessionsKey) {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await model.refreshSessions()
            }
            .toolbar {
                if let hostPicker {
                    // 主機挑選鈕佔標題位置(原型);頁面只顯示標題，不放說明。
                    ToolbarItem(placement: .principal) {
                        SheetHostPicker(model: hostPicker, identifier: "newChat.host")
                            .disabled(model.isStarting)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(model.isStarting)
                        .accessibilityIdentifier("newChat.cancel")
                }
            }
        }
        // 部分高度的系統 sheet,系統自動套玻璃(#425);鍵盤升起或內容多時系統自動拉到 large。
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 一份清單(#309,選定版 C):第一列「新的聊天」,下面是這個資料夾過去的 session;勾號只有一個。
    @ViewBuilder
    private var sessionsSection: some View {
        switch model.sessions {
        case .idle:
            EmptyView()
        case .loading:
            // 讀這個資料夾過去的 session:同形狀的列骨架(#496)。
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<2, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "Previous chat summary placeholder")
                            Text(verbatim: "Resume · yesterday").font(.footnote)
                        }
                    }
                }
                .padding(.vertical, 4)
                .skeleton(identifier: "newChat.sessions.loading")
            } header: {
                Text("Chat").foregroundStyle(.secondaryText)
            }
        case .unavailable(let reason):
            Section {
                Text(reason)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("newChat.sessions.unavailable")
            } header: {
                Text("Chat").foregroundStyle(.secondaryText)
            }
        case .updateRequired(let commands):
            Section {
                HostServiceCommandRows(
                    message: "Update the Purrdr host service to resume past chats. Run this on the computer:",
                    commands: commands, identifier: "newChat.sessions.update")
            } header: {
                Text("Chat").foregroundStyle(.secondaryText)
            }
        case .failed(let message):
            Section {
                ErrorLabel(message)
                    .accessibilityIdentifier("newChat.sessions.error")
                Button("Try Again") { Task { await model.refreshSessions() } }
                    .accessibilityIdentifier("newChat.sessions.retry")
            } header: {
                Text("Chat").foregroundStyle(.secondaryText)
            }
        case .loaded(let sessions):
            Section {
                Picker("Chat", selection: $model.choice) {
                    Label("New Chat", systemImage: "plus")
                        .tag(NewChatModel.Choice.new)
                        .accessibilityIdentifier("newChat.session.new")
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: session.summary ?? String(session.id.prefix(8)))
                                .lineLimit(2)
                            Text(verbatim: Self.subtitle(for: session))
                                .font(.footnote)
                                .foregroundStyle(.secondaryText)
                        }
                        .tag(NewChatModel.Choice.resume(session.id))
                        .accessibilityIdentifier("newChat.session.\(session.id)")
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("newChat.sessions")
            } header: {
                Text("Chat").foregroundStyle(.secondaryText)
            }
        }
    }

    /// 「續接 · 時間」。主機服務的清單沒有輪數,所以副標只有時間。
    private static func subtitle(for session: ResumableSession) -> String {
        let resume = String(localized: "Resume")
        guard let modified = session.modified else { return resume }
        return "\(resume) · \(modified.formatted(.relative(presentation: .named)))"
    }

    private func start() {
        Task {
            if let created = await model.start() { onStarted(created, model.unsentMessage) }
        }
    }
}

/// 新增對話的資料夾瀏覽(行為規格 F3.3):只列子資料夾;錯誤與空資料夾分開顯示。
/// 樣式比照檔案頁(實機回報 2026-11-20):上方路徑麵包屑(每段可點回那一層，取代「上一層」)、資料夾列同檔案頁。
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if !model.breadcrumbs.isEmpty {
                    FolderBreadcrumbBar(crumbs: model.breadcrumbs, identifierPrefix: "folderPicker.crumb.") { crumb in
                        Task { await model.go(to: crumb) }
                    }
                }
            }
            .toolbar {
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
            // 讀資料夾清單:同檔案頁的資料夾列骨架(#496)。
            List {
                Section {
                    FolderSkeletonRows(count: SkeletonLoading.defaultRowCount, identifier: "folderPicker.loading", label: "Loading folders…")
                }
            }
            .appSheetList()
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
                        FolderEntryRow(entry: FolderEntry(name: name, kind: .folder, size: 0), identifierPrefix: "folderPicker.row.") {
                            Task { await model.open(name) }
                        }
                    }
                }
            }
            .appSheetList()
            .accessibilityIdentifier("folderPicker.list")
        }
    }
}
