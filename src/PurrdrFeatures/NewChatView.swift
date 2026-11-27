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
                    if model.availableAgents.isEmpty {
                        // 系統空狀態(#626)。
                        ContentUnavailableView(
                            "No Agents Turned On", systemImage: "bubble.left.and.bubble.right",
                            description: Text("No Agents are turned on for this host. Open the Hosts tab, then Agent, to turn one on."))
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier("newChat.noAgents")
                    }
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
                }

                if model.selectedWorkspace == nil {
                Section {
                    TextField("Folder", text: $model.folder, prompt: Text(verbatim: model.canBrowseFolders ? "~/projects/app" : "/Users/you/projects/app"))
                        .inputFieldTint()
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .accessibilityIdentifier("newChat.folder")
                    if model.canBrowseFolders {
                        NavigationLink {
                            FolderPickerRoot(model: model)
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
                }

                sessionsSection

                Section {
                    if model.selectedWorkspace == nil {
                        TextField("Workspace Name", text: $model.workspaceName, prompt: Text("Optional"))
                            .inputFieldTint()
                            .accessibilityIdentifier("newChat.workspaceName")
                    }
                    TextField("Tab Name", text: $model.tabName, prompt: Text("Optional"))
                        .inputFieldTint()
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
                        .inputFieldTint()
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

                if let error = model.failure {
                    Section {
                        ErrorLabel(error.text, area: "NewChatView", error: error.descriptor)
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
            // identifier 放在 `appGroupedList()` 之前:它疊的頂端淡模糊(#683)若在 identifier 之後,會被套上同一個 identifier,
            // UI 測試的 `newChat.page` 變成兩個,`firstMatch` 抓到 54pt 高的那條而不是捲動容器(`NewChatPageIdentifierTests`)。
            .accessibilityIdentifier("newChat.page")
            .appGroupedList()
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
                            // 確認對話框掛在觸發的返回鈕上,錨定在鈕(#625)。
                            .confirmationDialog("Discard this new chat?", isPresented: $confirmingLeave, titleVisibility: .visible) {
                                Button("Discard", role: .destructive, action: onLeave)
                                Button("Keep Editing", role: .cancel) {}
                            }
                    }
                }
                if let hostPicker {
                    ToolbarItem(placement: .primaryAction) {
                        HostMenuButton(model: hostPicker, identifier: "newChat.host")
                            .disabled(model.isStarting)
                    }
                }
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
                ErrorLabel(message.text, area: "NewChatView", error: message.descriptor)
                    .accessibilityIdentifier("newChat.sessions.error")
                Button("Try Again") { Task { await model.refreshSessions() } }
                    .listAction()
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

/// 資料夾瀏覽這一串 push 共用的狀態:每一層出現時登記自己的路徑與「退出這一層」的動作。
/// 系統導覽只有「退出最上面這一層」(`dismiss` 對被蓋住的層沒有作用),所以:
/// 麵包屑跳回前面某一層 = 從上往下一層一層退(`pop(toDepth:)`),「Use This Folder」= 退光整串(`unwind`);
/// 每退一層,露出來的那一層看到 `unwinding` 就接著退自己。
@MainActor
@Observable
final class FolderPickerFlow {
    private(set) var paths: [Int: String] = [:]
    /// 退回到這一層為止(它之上的都退掉);`nil` 沒有在退。-1 是整串退光(回到新增聊天表單)。
    private(set) var unwindTarget: Int?
    @ObservationIgnored private var exits: [Int: DismissAction] = [:]

    func register(depth: Int, path: String?, exit: DismissAction) {
        if let path { paths[depth] = path }
        exits[depth] = exit
    }

    /// 前面走過、路徑是 `path` 的那一層(比 `depth` 淺)。
    func depth(ofPath path: String, below depth: Int) -> Int? {
        paths.filter { $0.key < depth && $0.value == path }.keys.max()
    }

    /// 退回 `target` 層:從目前最上面這一層(`from`)開始退。
    func pop(toDepth target: Int, from depth: Int) {
        guard depth > target else { return }
        unwindTarget = target
        exits[depth]?()
    }

    /// 退光整串(使用資料夾後回到表單)。
    func unwind(from depth: Int) { pop(toDepth: -1, from: depth) }

    /// 一層露出來了:還在退而且它在目標之上就接著退自己;退到目標層就結束。
    func didReveal(depth: Int) {
        guard let target = unwindTarget else { return }
        if depth > target {
            exits[depth]?()
        } else {
            unwindTarget = nil
        }
    }

    /// 整串退光、第一層也離開時清掉狀態。
    func didLeaveRoot() { unwindTarget = nil }
}

/// 新增對話的資料夾瀏覽第一層:自己持有一個 model(從表單已填的資料夾或家目錄開始),使用資料夾後整串 push 一起收掉。
private struct FolderPickerRoot: View {
    let model: NewChatModel
    @State private var picker: FolderPickerModel
    @State private var flow = FolderPickerFlow()

    init(model: NewChatModel) {
        self.model = model
        _picker = State(wrappedValue: model.makeFolderPicker())
    }

    var body: some View {
        FolderPickerLevelView(model: picker, depth: 0, flow: flow, onChoose: { model.choose($0) })
            .onDisappear { if flow.unwindTarget == -1 { flow.didLeaveRoot() } }
    }
}

/// 資料夾瀏覽的一層(#621、#620 的 push 規則):點子資料夾 push 下一層(系統 `NavigationLink`;新增聊天本身是 isPresented 的 push,
/// 裡面用「值的導覽」會讓系統把新增聊天又推一次,所以這裡的連結都是帶目的地的 NavigationLink)、左上系統「<」回上一層、
/// 每層有大標題,路徑麵包屑留著當快速跳層;「Use This Folder」在任何一層都能用,選了就把整串收掉。
struct FolderPickerLevelView: View {
    @State var model: FolderPickerModel
    let depth: Int
    let flow: FolderPickerFlow
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FolderPickerView(
            model: model, title: title, flow: flow, depth: depth, onChoose: onChoose, jump: jump,
            choose: { path in
                onChoose(path)
                flow.unwind(from: depth)
            }
        )
        .onAppear {
            flow.register(depth: depth, path: model.chosenPath, exit: dismiss)
            flow.didReveal(depth: depth)
        }
        .onChange(of: model.chosenPath) { _, path in flow.register(depth: depth, path: path, exit: dismiss) }
    }

    private var title: LocalizedStringKey {
        depth == 0 ? "Choose Folder" : LocalizedStringKey(model.chosenPath.map { ($0 as NSString).lastPathComponent } ?? "Choose Folder")
    }

    /// 點麵包屑:退回前面走過的那一層。
    private func jump(_ crumb: FolderBreadcrumb) {
        guard crumb.path != model.chosenPath, let target = flow.depth(ofPath: crumb.path, below: depth) else { return }
        flow.pop(toDepth: target, from: depth)
    }
}

/// 新增對話的資料夾瀏覽(行為規格 F3.3):只列子資料夾;錯誤與空資料夾分開顯示。
/// 樣式比照檔案頁(實機回報 2026-11-20):上方路徑麵包屑(每段可點回那一層，取代「上一層」)、資料夾列同檔案頁。
struct FolderPickerView: View {
    let model: FolderPickerModel
    let title: LocalizedStringKey
    let flow: FolderPickerFlow
    let depth: Int
    let onChoose: (String) -> Void
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
                // 只列走過的層(點了退回那一層)與目前這一層。
                let crumbs = model.breadcrumbs.filter { $0.path == model.chosenPath || flow.depth(ofPath: $0.path, below: depth) != nil }
                if !crumbs.isEmpty {
                    FolderBreadcrumbBar(crumbs: crumbs, identifierPrefix: "folderPicker.crumb.", go: jump)
                }
            }
            // 完成動作在右上 ✓(同有確認動作的畫面;tab bar 保留著,所以不放在底部工具列,會與 tab bar 重疊)。
            .toolbar {
                ModalConfirmToolbar(title: "Use This Folder", identifier: "folderPicker.use", isEnabled: model.chosenPath != nil) {
                    guard let path = model.chosenPath else { return }
                    choose(path)
                }
            }
            .task { await model.load() }
    }

    @ViewBuilder
    private func folderRow(_ name: String) -> some View {
        let entry = FolderEntry(name: name, kind: .folder, size: 0)
        if let child = model.childPath(name) {
            NavigationLink {
                FolderPickerLevelView(model: model.child(at: child), depth: depth + 1, flow: flow, onChoose: onChoose)
            } label: {
                FolderEntryLabel(entry: entry)
            }
            .accessibilityIdentifier("folderPicker.row.\(name)")
        } else {
            FolderEntryLabel(entry: entry)
                .accessibilityIdentifier("folderPicker.row.\(name)")
        }
    }

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
                Text(message.text)
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
                            folderRow(name)
                        }
                    }
                }
                .appGroupedList()
                .accessibilityIdentifier("folderPicker.list")
            }
        }
    }
}
