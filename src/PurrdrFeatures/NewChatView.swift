import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH
import SwiftUI

/// 新增對話(#272,原型 purrdr-screens 定案版):標題列中間是主機挑選鈕，下面是 Agent(攤開的勾選列,#313)、資料夾、第一則訊息，
/// 最下方「開始」。名稱由 herdr 用資料夾名，權限沿用 agent 自己的設定。
///
/// 從聊天 tab 往右 push 進來(#621,spec #612):左上系統「<」離開、有大標題,選主機是右上電腦圖示選單。
/// 資料夾瀏覽每往下一層也是 push。有未送出的輸入時離開先確認;開始中不能離開(主機上正在建立 workspace)。
public struct NewChatView: View {
    @Bindable var model: NewChatModel
    /// 右上電腦圖示選單的主機選擇(#245、#621)。
    let hostPicker: HostPickerModel?
    /// 離開新增聊天(左上「<」、確認放棄後)。
    let onLeave: () -> Void
    /// 開始了：新 workspace 與沒送出的第一則訊息(agent 停在啟動問題時)。
    let onStarted: (CreatedWorkspace, String?) -> Void

    public init(
        model: NewChatModel, hostPicker: HostPickerModel? = nil, onLeave: @escaping () -> Void,
        onStarted: @escaping (CreatedWorkspace, String?) -> Void
    ) {
        self.model = model
        self.hostPicker = hostPicker
        self.onLeave = onLeave
        self.onStarted = onStarted
    }

    @State private var confirmingLeave = false

    /// 有輸入或正在開始時系統返回鈕換成會確認的「<」(同時關掉左緣滑動返回)。
    private var interceptsBack: Bool { model.hasUnsentInput || model.isStarting }

    public var body: some View {
        form
            // 離開(返回、確認放棄、開好聊天後被收掉):agent 沒啟動成功時建了一半的 Workspace／Tab 關掉(成功時沒有東西要關)。
            // 往下推資料夾瀏覽時也會經過這裡:此時只會關掉上次開始失敗留下的半成品,下一次開始本來就會重建,沒有副作用。
            .onDisappear { [model] in Task { await model.discardUnstarted() } }
    }

    private var form: some View {
        Group {
            Form {
                if model.canChooseExistingWorkspace {
                    placementSection
                }

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

                if model.selectedWorkspace == nil {
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
                        NavigationLink(value: NewChatFolderRoute()) {
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
                }

                sessionsSection

                Section {
                    if model.selectedWorkspace == nil {
                        TextField("Workspace Name", text: $model.workspaceName, prompt: Text("Optional"))
                            .accessibilityIdentifier("newChat.workspaceName")
                    }
                    TextField("Tab Name", text: $model.tabName, prompt: Text("Optional"))
                        .accessibilityIdentifier("newChat.tabName")
                } header: {
                    Text(model.selectedWorkspace == nil ? "Names" : "Name")
                        .foregroundStyle(.secondaryText)
                } footer: {
                    if model.selectedWorkspace == nil {
                        Text("Leave these empty to use the folder’s name.")
                    } else {
                        Text("Leave this empty to use the default name.")
                    }
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
                        ErrorLabel(error, area: "NewChatView")
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
            .appGroupedList()
            .accessibilityIdentifier("newChat.page")
            .navigationTitle("New Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .navigationBarBackButtonHidden(interceptsBack)
            #endif
            .task(id: ObjectIdentifier(model)) { await model.loadAccess() }
            .task(id: ObjectIdentifier(model)) { await model.loadWorkspaces() }
            // 資料夾或 agent 變了就重讀過去的 session;打字時等一下再讀(#309)。
            .task(id: model.sessionsKey) {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await model.refreshSessions()
            }
            .toolbar {
                if interceptsBack {
                    ToolbarItem(placement: .navigation) {
                        Button { confirmingLeave = true } label: { Image(systemName: "chevron.left") }
                            .disabled(model.isStarting)
                            .accessibilityLabel(Text("Back"))
                            .accessibilityIdentifier("newChat.back")
                    }
                }
                if let hostPicker {
                    ToolbarItem(placement: .primaryAction) {
                        HostMenuButton(model: hostPicker, identifier: "newChat.host")
                            .disabled(model.isStarting)
                    }
                }
            }
            .confirmationDialog("Discard this new chat?", isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button("Discard", role: .destructive, action: onLeave)
                Button("Keep Editing", role: .cancel) {}
            }
            .navigationDestination(for: NewChatFolderRoute.self) { _ in
                FolderPickerRoot(model: model)
            }
        }
    }

    /// 放在哪裡(#537):新的 Workspace,或這台主機目前開著的 Workspace(在裡面新增一個 Tab)。
    private var placementSection: some View {
        Section {
            Picker("Workspace", selection: $model.placement) {
                Label("New Workspace", systemImage: "plus")
                    .tag(NewChatModel.Placement.newWorkspace)
                ForEach(model.workspaces) { workspace in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: workspace.name ?? String(localized: "Untitled Workspace"))
                            .lineLimit(1)
                        if let folder = workspace.folder {
                            Text(verbatim: folder)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .tag(NewChatModel.Placement.existing(workspace.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("newChat.placement")
        } header: {
            Text("Workspace")
                .foregroundStyle(.secondaryText)
        } footer: {
            if model.selectedWorkspace != nil {
                Text("A new Tab opens in this Workspace.")
                    .accessibilityIdentifier("newChat.placement.footer")
            }
        }
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
                ErrorLabel(message, area: "NewChatView")
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

/// 往資料夾瀏覽的導覽值(新增聊天的「Choose Folder on Host」列)。
struct NewChatFolderRoute: Hashable {}

/// 資料夾瀏覽往下一層的導覽值:`depth` 是那一層在串裡的位置(第一層 0,所以往下的第一層是 1)。
struct FolderPickerRoute: Hashable {
    var path: String
    var depth: Int
}

/// 資料夾瀏覽這一串 push 共用的狀態:每一層出現時登記自己的路徑與「退出這一層」的動作,
/// 麵包屑跳回前面某一層、或「Use This Folder」把整串收掉都靠它(系統導覽沒有「退到第 n 層」,只能退出某一層)。
@MainActor
@Observable
final class FolderPickerFlow {
    private(set) var paths: [Int: String] = [:]
    @ObservationIgnored private var exits: [Int: DismissAction] = [:]
    @ObservationIgnored var finish: () -> Void = {}

    func register(depth: Int, path: String?, exit: DismissAction) {
        if let path { paths[depth] = path }
        exits[depth] = exit
    }

    /// 退回 `depth` 層(它之上的各層都收掉):退出它的下一層。
    func pop(toDepth depth: Int) { exits[depth + 1]?() }

    func depth(ofPath path: String, below depth: Int) -> Int? {
        paths.filter { $0.key < depth && $0.value == path }.keys.max()
    }
}

/// 新增對話的資料夾瀏覽第一層:自己持有一個 model(從表單已填的資料夾或家目錄開始),使用資料夾後整串 push 一起收掉。
private struct FolderPickerRoot: View {
    let model: NewChatModel
    @State private var picker: FolderPickerModel
    @State private var flow = FolderPickerFlow()
    @Environment(\.dismiss) private var dismiss

    init(model: NewChatModel) {
        self.model = model
        _picker = State(wrappedValue: model.makeFolderPicker())
    }

    var body: some View {
        FolderPickerLevelView(model: picker, depth: 0, flow: flow, onChoose: { model.choose($0) })
            .navigationDestination(for: FolderPickerRoute.self) { route in
                FolderPickerLevelView(model: picker.child(at: route.path), depth: route.depth, flow: flow, onChoose: { model.choose($0) })
            }
            .onAppear { flow.finish = { dismiss() } }
    }
}

/// 資料夾瀏覽的一層(#621、#620 的 push 規則):點子資料夾 push 下一層(系統 `NavigationLink`)、左上系統「<」回上一層、
/// 每層有大標題,路徑麵包屑留著當快速跳層;「Use This Folder」在任何一層都能用,選了就把整串收掉。
struct FolderPickerLevelView: View {
    @State var model: FolderPickerModel
    let depth: Int
    let flow: FolderPickerFlow
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    /// 麵包屑點到沒走過的一層(家目錄以上)時往下推。
    @State private var crumbTarget: FolderPickerRoute?

    var body: some View {
        FolderPickerView(
            model: model, title: title, depth: depth, jump: jump,
            choose: { path in
                onChoose(path)
                flow.finish()
            }
        )
        .navigationDestination(item: $crumbTarget) { route in
            FolderPickerLevelView(model: model.child(at: route.path), depth: route.depth, flow: flow, onChoose: onChoose)
        }
        .onAppear { flow.register(depth: depth, path: model.chosenPath, exit: dismiss) }
        .onChange(of: model.chosenPath) { _, path in flow.register(depth: depth, path: path, exit: dismiss) }
    }

    private var title: LocalizedStringKey {
        depth == 0 ? "Choose Folder" : LocalizedStringKey(model.chosenPath.map { ($0 as NSString).lastPathComponent } ?? "Choose Folder")
    }

    /// 點麵包屑:前面某一層就退回去;沒走過的(家目錄以上)往下推一層。
    private func jump(_ crumb: FolderBreadcrumb) {
        guard crumb.path != model.chosenPath else { return }
        if let target = flow.depth(ofPath: crumb.path, below: depth) {
            flow.pop(toDepth: target)
        } else {
            crumbTarget = FolderPickerRoute(path: crumb.path, depth: depth + 1)
        }
    }
}

/// 新增對話的資料夾瀏覽(行為規格 F3.3):只列子資料夾;錯誤與空資料夾分開顯示。
/// 樣式比照檔案頁(實機回報 2026-11-20):上方路徑麵包屑(每段可點回那一層，取代「上一層」)、資料夾列同檔案頁。
struct FolderPickerView: View {
    let model: FolderPickerModel
    let title: LocalizedStringKey
    let depth: Int
    let jump: (FolderBreadcrumb) -> Void
    let choose: (String) -> Void

    var body: some View {
        content
            .appPageContentWidth()
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .safeAreaBar(edge: .top) {
                if !model.breadcrumbs.isEmpty {
                    FolderBreadcrumbBar(crumbs: model.breadcrumbs, identifierPrefix: "folderPicker.crumb.", go: jump)
                }
            }
            .toolbar {
                ToolbarItem(placement: Self.usePlacement) {
                    Button("Use This Folder") {
                        guard let path = model.chosenPath else { return }
                        choose(path)
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
            .appGroupedList()
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
            if listing.folders.isEmpty {
                ContentUnavailableView("No Folders", systemImage: "folder", description: Text("You can still use this folder."))
                    .accessibilityIdentifier("folderPicker.empty")
            } else {
                List {
                    Section {
                        ForEach(listing.folders, id: \.self) { name in
                            FolderEntryRow(
                                entry: FolderEntry(name: name, kind: .folder, size: 0), identifierPrefix: "folderPicker.row.",
                                route: model.childPath(name).map { FolderPickerRoute(path: $0, depth: depth + 1) })
                        }
                    }
                }
                .appGroupedList()
                .accessibilityIdentifier("folderPicker.list")
            }
        }
    }
}
