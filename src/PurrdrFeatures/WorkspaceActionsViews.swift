import Observation
import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 列表上要呈現的 workspace 操作畫面(sheet 與確認)。由列的滑動、context menu 設定，列表統一呈現。
@MainActor
@Observable
final class WorkspacePresentation {
    enum Sheet: Identifiable {
        case worktree(workspaceID: String, label: String)
        case layout(workspaceLabel: String, layout: SpacesLayout?)

        var id: String {
            switch self {
            case .worktree(let id, _): "worktree.\(id)"
            case .layout(let label, _): "layout.\(label)"
            }
        }
    }

    struct CloseRequest {
        var workspaceID: String
        var label: String
        var sessionIDs: [String]
    }

    var sheet: Sheet?
    /// 重新命名提示框(#456):Workspace 與 Tab 共用,系統帶輸入框的 alert。
    var renameRequest: RenameRequest?
    /// 提示框裡的輸入;失敗後重新呈現時保留。
    var renameText = ""
    /// 上一次送出失敗的原因(重新呈現的提示框顯示)。
    var renameFailure: String?
    var closeRequest: CloseRequest?
    /// 操作的是哪台主機(多主機合併列表，#39)。列設定 sheet 或確認時一併設定。
    var host: HostSelection = .demo
    /// 版面圖裡點選的 Pane:先記下、關 sheet 之後才開(不能在關 sheet 的同一刻 push,行為規格 F4)。
    var chosenTarget: PaneOpenTarget?
}

/// 重新命名的對象:Workspace 或 Tab,與目前名稱。
struct RenameRequest: Equatable {
    enum Kind: Equatable {
        case workspace(id: String)
        /// Tab 所在的 Workspace 名稱用在說明文字。
        case tab(id: String, workspaceLabel: String)
    }

    var kind: Kind
    var original: String
}

/// 一個 Tab 的操作對象:id 與目前名稱(herdr 沒有名稱時是順序號)。
struct TabTarget {
    var tabID: String
    var label: String
    var workspaceLabel: String

    init?(tabID: String?, snapshot: HostSnapshot?, workspaceLabel: String) {
        guard let tabID, let tab = snapshot?.tabs.first(where: { $0.id == tabID }) else { return nil }
        self.tabID = tabID
        label = tab.label ?? String(tab.number)
        self.workspaceLabel = workspaceLabel
    }
}

/// 一個 workspace 的操作對象：id、名稱與它所有 Agent 的 session(關閉時一併清掉本機偏好)。
struct WorkspaceTarget {
    var workspaceID: String
    var label: String
    var sessionIDs: [String]

    init(workspaceID: String, label: String, snapshot: HostSnapshot?) {
        self.workspaceID = workspaceID
        self.label = label
        sessionIDs = snapshot?.agents.filter { $0.workspaceID == workspaceID }.compactMap(\.sessionID) ?? []
    }
}

/// Tab 列長按選單的釘選與靜音:這個 Tab 底下所有 Agent 的 session 與該主機的操作 model。
struct TabChatActions {
    var actions: WorkspaceActionsModel
    var sessionIDs: [String]

    init?(actions: WorkspaceActionsModel?, sessionIDs: [String]) {
        guard let actions, !sessionIDs.isEmpty else { return nil }
        self.actions = actions
        self.sessionIDs = sessionIDs
    }
}

/// 一個 workspace 在列表裡的身分：列的操作需要的值。
struct WorkspaceRowContext {
    var agent: Agent
    var workspace: WorkspaceTarget
    /// Agent 所在的 Tab(snapshot 沒有它時為 nil)。
    var tab: TabTarget?

    init?(paneID: String, snapshot: HostSnapshot?) {
        guard let snapshot, let agent = snapshot.agents.first(where: { $0.paneID == paneID }) else { return nil }
        self.agent = agent
        let label = snapshot.workspaces.first { $0.id == agent.workspaceID }?.label ?? agent.workspaceID
        workspace = WorkspaceTarget(workspaceID: agent.workspaceID, label: label, snapshot: snapshot)
        tab = TabTarget(tabID: agent.tabID, snapshot: snapshot, workspaceLabel: label)
    }
}

extension View {
    /// 列的滑動與 context menu(行為規格 F2.7)。context menu 頂端的動作與滑動相同;破壞性的「關閉」放最後。
    ///
    /// `openInNewWindow` 有值時(支援多視窗)，context menu 最前面加「在新視窗開啟」(HIG Windows,#31)。
    func workspaceRowActions(
        _ context: WorkspaceRowContext?, host: HostSelection, actions: WorkspaceActionsModel?, presentation: WorkspacePresentation,
        snapshot: HostSnapshot?, openInNewWindow: ((PaneWindow.Kind) -> Void)? = nil
    ) -> some View {
        modifier(WorkspaceRowActions(
            context: context, host: host, actions: actions, presentation: presentation, snapshot: snapshot,
            openInNewWindow: openInNewWindow))
    }

    /// Spaces 檢視 Tab 列的 context menu(#275、#491 補回釘選與靜音):最前面是「在新視窗開啟」(支援多視窗時)與釘選、靜音,
    /// 接著版面圖，其餘同列的 workspace 動作。
    ///
    /// Tab 可能有多個 Agent:釘選與靜音作用在底下所有 Agent 的聊天(`sessionIDs`,沒有 session 時不顯示)。
    /// 改名改的是這個 Tab;Workspace 名稱在段落標題的長按選單(`workspaceHeaderMenu`,#456)。`tab` 為 nil(沒有 Tab 的 pane)時沒有改名項目。
    func workspaceActionsMenu(
        _ target: WorkspaceTarget, tab: TabTarget?, host: HostSelection, snapshot: HostSnapshot?, presentation: WorkspacePresentation,
        chats: TabChatActions? = nil, openInNewWindow: (() -> Void)? = nil
    ) -> some View {
        contextMenu {
            let buttons = WorkspaceButtons(target: target, host: host, snapshot: snapshot, presentation: presentation)
            if let openInNewWindow {
                Button("Open in New Window", systemImage: "macwindow.badge.plus", action: openInNewWindow)
                    .accessibilityIdentifier("menu.openInNewWindow")
            }
            if let chats {
                let pinned = chats.actions.arePinned(sessionIDs: chats.sessionIDs)
                Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                    chats.actions.togglePin(sessionIDs: chats.sessionIDs)
                }
                .accessibilityIdentifier("menu.pin")
                let muted = chats.actions.areMuted(sessionIDs: chats.sessionIDs)
                Button(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash") {
                    chats.actions.toggleMute(sessionIDs: chats.sessionIDs)
                }
                .accessibilityIdentifier("menu.mute")
            }
            if openInNewWindow != nil || chats != nil { Divider() }
            buttons.showLayout()
            if let tab { buttons.renameTab(tab, showsCurrent: false) }
            buttons.newWorktree()
            Divider()
            buttons.close(title: "Close Workspace…", role: .destructive)
        }
    }

    /// Spaces 檢視段落標題的長按選單(#456):List 的段落標題掛不上 `contextMenu`，
    /// 所以標題本身是 `Menu`(輕點不做事、長按出選單):重新命名 Workspace…、版面圖、新 worktree、關閉。
    /// VoiceOver 另有「重新命名 Workspace…」自訂動作。唯讀裝置的改動項目停用。
    func workspaceHeaderMenu(
        _ target: WorkspaceTarget, host: HostSelection, snapshot: HostSnapshot?, isReadOnly: Bool, presentation: WorkspacePresentation
    ) -> some View {
        let buttons = WorkspaceButtons(target: target, host: host, snapshot: snapshot, presentation: presentation, isReadOnly: isReadOnly)
        return Menu {
            buttons.renameWorkspace(showsCurrent: true)
            buttons.showLayout()
            buttons.newWorktree()
            Divider()
            buttons.close(title: "Close Workspace…", role: .destructive)
            if isReadOnly { Text(WorkspaceActionsModel.readOnlyMessage) }
        } label: {
            self
        } primaryAction: {}
        .buttonStyle(.plain)
        .accessibilityAction(named: Text("Rename Workspace…")) { if !isReadOnly { buttons.askWorkspaceName() } }
    }

    /// 呈現 workspace 操作的 sheet、確認與錯誤。`actions` 依主機取得該主機的操作;
    /// `onOpen` 在版面圖選了 Pane 且 sheet 關閉之後呼叫(帶主機)。
    func workspaceActionsPresentation(
        actions: @escaping (HostSelection) -> WorkspaceActionsModel?, presentation: WorkspacePresentation,
        onOpen: @escaping (HostSelection, PaneOpenTarget) -> Void
    ) -> some View {
        modifier(WorkspaceActionsPresenter(resolve: actions, presentation: presentation, onOpen: onOpen))
    }
}

/// Agent 列與 Spaces 的 Tab 列共用的 workspace 動作按鈕。
@MainActor
private struct WorkspaceButtons {
    let target: WorkspaceTarget
    let host: HostSelection
    let snapshot: HostSnapshot?
    let presentation: WorkspacePresentation
    /// 唯讀裝置：改到主機的操作(改名、建立 worktree、關閉)停用。
    var isReadOnly = false

    /// 改的是 workspace 名稱，不一定是列標題，所以滑動上叫「Workspace」而不叫「重新命名」(行為規格 F2.7)。
    func rename(title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "pencil") { askWorkspaceName() }
            .tint(.gray)
            .disabled(isReadOnly)
    }

    /// context menu 的「重新命名 Workspace…」;`showsCurrent` 時副標顯示目前名稱(#456)。
    func renameWorkspace(showsCurrent: Bool) -> some View {
        Button { askWorkspaceName() } label: {
            Text("Rename Workspace…")
            if showsCurrent { Text("Current: \(target.label)") }
            Image(systemName: "pencil")
        }
        .accessibilityIdentifier("menu.renameWorkspace")
        .disabled(isReadOnly)
    }

    /// 「重新命名 Tab…」(#456)。
    func renameTab(_ tab: TabTarget, showsCurrent: Bool) -> some View {
        Button {
            presentation.host = host
            presentation.renameFailure = nil
            presentation.renameText = tab.label
            presentation.renameRequest = RenameRequest(
                kind: .tab(id: tab.tabID, workspaceLabel: tab.workspaceLabel), original: tab.label)
        } label: {
            Text("Rename Tab…")
            if showsCurrent { Text("Current: \(tab.label)") }
            Image(systemName: "pencil")
        }
        .accessibilityIdentifier("menu.renameTab")
        .disabled(isReadOnly)
    }

    func askWorkspaceName() {
        presentation.host = host
        presentation.renameFailure = nil
        presentation.renameText = target.label
        presentation.renameRequest = RenameRequest(kind: .workspace(id: target.workspaceID), original: target.label)
    }

    func close(title: LocalizedStringKey, role: ButtonRole?) -> some View {
        Button(title, systemImage: "xmark.circle", role: role) {
            presentation.host = host
            presentation.closeRequest = .init(workspaceID: target.workspaceID, label: target.label, sessionIDs: target.sessionIDs)
        }
        .disabled(isReadOnly)
    }

    func showLayout() -> some View {
        Button("Show Layout", systemImage: "rectangle.split.3x1") {
            // 顯示開啟當下的 snapshot,不即時更新(行為規格 F4)。
            presentation.host = host
            presentation.sheet = .layout(
                workspaceLabel: target.label, layout: snapshot.flatMap { SpacesLayout(snapshot: $0, workspaceID: target.workspaceID) })
        }
    }

    func newWorktree() -> some View {
        Button("New Worktree…", systemImage: "arrow.triangle.branch") {
            presentation.host = host
            presentation.sheet = .worktree(workspaceID: target.workspaceID, label: target.label)
        }
        .disabled(isReadOnly)
    }
}

private struct WorkspaceRowActions: ViewModifier {
    let context: WorkspaceRowContext?
    let host: HostSelection
    let actions: WorkspaceActionsModel?
    let presentation: WorkspacePresentation
    let snapshot: HostSnapshot?
    let openInNewWindow: ((PaneWindow.Kind) -> Void)?

    func body(content: Content) -> some View {
        if let context, let actions {
            let buttons = WorkspaceButtons(
                target: context.workspace, host: host, snapshot: snapshot, presentation: presentation, isReadOnly: actions.isReadOnly)
            content
                // 列表是根畫面，沒有返回手勢的邊緣，leading 滑動是安全的。
                .swipeActions(edge: .leading) {
                    chatButtons(context, actions: actions)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // 滑動上不用 `.destructive` role:List 會在確認前就把列移走;以系統紅標示，確認對話框裡才是 destructive。
                    buttons.close(title: "Close", role: nil)
                        .tint(WorkspaceSwipeAction.close.tint.style)
                    buttons.rename(title: "Workspace")
                        .tint(WorkspaceSwipeAction.workspace.tint.style)
                }
                .contextMenu {
                    if let openInNewWindow {
                        Button("Open in New Window", systemImage: "macwindow.badge.plus") { openInNewWindow(.chat) }
                            .accessibilityIdentifier("menu.openInNewWindow")
                        Button("Open Terminal in New Window", systemImage: "apple.terminal") { openInNewWindow(.terminal) }
                            .accessibilityIdentifier("menu.openTerminalInNewWindow")
                        Divider()
                    }
                    chatButtons(context, actions: actions)
                    if let tab = context.tab { buttons.renameTab(tab, showsCurrent: true) }
                    buttons.renameWorkspace(showsCurrent: true)
                    buttons.showLayout()
                    buttons.newWorktree()
                    Divider()
                    buttons.close(title: "Close Workspace…", role: .destructive)
                    if actions.isReadOnly {
                        // 唯讀裝置(HTTPS 主機):說明上面的操作為什麼停用(#287)。
                        Text(WorkspaceActionsModel.readOnlyMessage)
                    }
                }
                .task(id: host) { await actions.loadAccess() }
        } else {
            content
        }
    }

    /// 釘選、靜音:只在 Agent 有 session 時提供(聊天以 session 識別)。
    @ViewBuilder
    private func chatButtons(_ context: WorkspaceRowContext, actions: WorkspaceActionsModel) -> some View {
        if let sessionID = context.agent.sessionID {
            let pinned = actions.isPinned(sessionID: sessionID)
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                actions.togglePin(sessionID: sessionID)
            }
            .tint(WorkspaceSwipeAction.pin.tint.style)
            let muted = actions.isMuted(sessionID: sessionID)
            Button(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash") {
                actions.toggleMute(sessionID: sessionID)
            }
            .tint(WorkspaceSwipeAction.mute.tint.style)
        }
    }
}

private struct WorkspaceActionsPresenter: ViewModifier {
    let resolve: (HostSelection) -> WorkspaceActionsModel?
    @Bindable var presentation: WorkspacePresentation
    let onOpen: (HostSelection, PaneOpenTarget) -> Void

    /// 目前操作的主機的 Workspace 操作。
    private var actions: WorkspaceActionsModel? { resolve(presentation.host) }

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentation.sheet, onDismiss: openChosenTarget) { sheet in
                if let actions { sheetContent(sheet, actions: actions) }
            }
            .alert(renameTitle, isPresented: renameShown, presenting: presentation.renameRequest) { request in
                TextField(renamePlaceholder(request), text: $presentation.renameText)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Rename") { submitRename(request) }
                    .disabled(!WorkspaceActionsModel.canRename(from: request.original, to: presentation.renameText))
            } message: { request in
                Text(renameMessage(request))
            }
            .confirmationDialog(
                closeTitle, isPresented: closeDialogShown, titleVisibility: .visible, presenting: presentation.closeRequest
            ) { request in
                Button("Close Workspace", role: .destructive) {
                    Task { await actions?.close(workspaceID: request.workspaceID, sessionIDs: request.sessionIDs) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Everything running in this workspace will stop, including its agents. Chat history stays on the host.")
            }
            .alert("Couldn’t Finish", isPresented: errorShown, presenting: actions?.actionError) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WorkspacePresentation.Sheet, actions: WorkspaceActionsModel) -> some View {
                switch sheet {
                case .worktree(let workspaceID, let label):
                    NewWorktreeSheet(actions: actions, workspaceID: workspaceID, workspaceLabel: label) { created in
                        presentation.chosenTarget = .terminal(paneID: created.rootPaneID)
                    }
                case .layout(let label, let layout):
                    SpacesLayoutSheet(workspaceLabel: label, layout: layout) { target in
                        presentation.chosenTarget = target
                    }
                }
    }

    private var renameTitle: Text {
        switch presentation.renameRequest?.kind {
        case .tab?: Text("Rename Tab")
        default: Text("Rename Workspace")
        }
    }

    private func renamePlaceholder(_ request: RenameRequest) -> LocalizedStringKey {
        switch request.kind {
        case .tab: "Tab name"
        case .workspace: "Workspace name"
        }
    }

    /// 說明電腦上的 herdr 也會改;上一次失敗時前面加原因。
    private func renameMessage(_ request: RenameRequest) -> String {
        let note: String = switch request.kind {
        case .tab(_, let workspaceLabel):
            String(localized: "The tab in “\(workspaceLabel)”. herdr on the host will be renamed too.")
        case .workspace:
            String(localized: "herdr on the host will be renamed too.")
        }
        return [presentation.renameFailure, note].compactMap { $0 }.joined(separator: "\n")
    }

    /// 送出;失敗時以同樣的輸入重新呈現提示框並說明原因(系統 alert 按鈕一定會關閉,所以重新呈現)。
    private func submitRename(_ request: RenameRequest) {
        guard let actions else { return }
        let text = presentation.renameText
        Task {
            let renamed: Bool
            switch request.kind {
            case .workspace(let id): renamed = await actions.rename(workspaceID: id, to: text)
            case .tab(let id, _): renamed = await actions.renameTab(tabID: id, to: text)
            }
            if renamed {
                presentation.renameFailure = nil
            } else {
                presentation.renameFailure = actions.renameError
                presentation.renameText = text
                presentation.renameRequest = request
            }
        }
    }

    private var renameShown: Binding<Bool> {
        Binding { presentation.renameRequest != nil } set: { if !$0 { presentation.renameRequest = nil } }
    }

    private var closeTitle: Text {
        Text("Close “\(presentation.closeRequest?.label ?? "")”?")
    }

    private var closeDialogShown: Binding<Bool> {
        Binding { presentation.closeRequest != nil } set: { if !$0 { presentation.closeRequest = nil } }
    }

    private var errorShown: Binding<Bool> {
        Binding { actions?.actionError != nil } set: { if !$0 { actions?.actionError = nil } }
    }

    private func openChosenTarget() {
        guard let target = presentation.chosenTarget else { return }
        presentation.chosenTarget = nil
        onOpen(presentation.host, target)
    }
}

// MARK: - 建立 worktree

/// 從 workspace 所在的 repo 建立 git worktree 與分支，開成新的 workspace。
struct NewWorktreeSheet: View {
    let actions: WorkspaceActionsModel
    let workspaceID: String
    let workspaceLabel: String
    let onCreated: (CreatedWorkspace) -> Void
    @State private var branch = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var canCreate: Bool {
        !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !actions.isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Branch", text: $branch)
                        .font(.body.monospaced())
                        .focused($focused)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .submitLabel(.done)
                        .onSubmit(create)
                        .accessibilityIdentifier("workspace.worktree.branch")
                } footer: {
                    Text("Creates a git worktree on a new branch from “\(workspaceLabel)” and opens it as its own workspace, so its files aren’t shared with other chats in the same repo.")
                        .foregroundStyle(.secondaryText)
                }
                if let error = actions.worktreeError {
                    Section {
                        ErrorLabel(error)
                            .accessibilityIdentifier("workspace.worktree.error")
                    }
                }
            }
            .appGroupedList()
            .navigationTitle("New Worktree")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actions.isWorking ? "Creating…" : "Create", action: create)
                        .disabled(!canCreate)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            actions.clearWorktreeError()
            focused = true
        }
    }

    private func create() {
        guard canCreate else { return }
        Task {
            if let created = await actions.createWorktree(from: workspaceID, branch: branch) {
                onCreated(created)
                dismiss()
            }
        }
    }
}

extension WorkspaceSwipeAction.Tint {
    /// 主色走 `prominentFill`(跟主機主題);灰用系統灰，跟滑動鈕預設一致。
    var style: AnyShapeStyle {
        switch self {
        case .accent: AnyShapeStyle(.prominentFill)
        case .gray: AnyShapeStyle(.gray)
        case .red: AnyShapeStyle(.red)
        }
    }
}
