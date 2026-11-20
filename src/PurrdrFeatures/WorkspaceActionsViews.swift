import Observation
import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 列表上要呈現的 workspace 操作畫面(sheet 與確認)。由列的滑動、context menu 設定，列表統一呈現。
@MainActor
@Observable
final class WorkspacePresentation {
    enum Sheet: Identifiable {
        case rename(workspaceID: String, label: String)
        case worktree(workspaceID: String, label: String)
        case layout(workspaceLabel: String, layout: SpacesLayout?)

        var id: String {
            switch self {
            case .rename(let id, _): "rename.\(id)"
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
    var closeRequest: CloseRequest?
    /// 操作的是哪台主機(多主機合併列表，#39)。列設定 sheet 或確認時一併設定。
    var host: HostSelection = .demo
    /// 版面圖裡點選的 Pane:先記下、關 sheet 之後才開(不能在關 sheet 的同一刻 push,行為規格 F4)。
    var chosenTarget: PaneOpenTarget?
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

/// 一個 workspace 在列表裡的身分：列的操作需要的值。
struct WorkspaceRowContext {
    var agent: Agent
    var workspace: WorkspaceTarget

    init?(paneID: String, snapshot: HostSnapshot?) {
        guard let snapshot, let agent = snapshot.agents.first(where: { $0.paneID == paneID }) else { return nil }
        self.agent = agent
        let label = snapshot.workspaces.first { $0.id == agent.workspaceID }?.label ?? agent.workspaceID
        workspace = WorkspaceTarget(workspaceID: agent.workspaceID, label: label, snapshot: snapshot)
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

    /// Spaces 檢視 Tab 列的 context menu(#275):第一項是版面圖，其餘同列的 workspace 動作。
    func workspaceActionsMenu(
        _ target: WorkspaceTarget, host: HostSelection, snapshot: HostSnapshot?, presentation: WorkspacePresentation
    ) -> some View {
        contextMenu {
            let buttons = WorkspaceButtons(target: target, host: host, snapshot: snapshot, presentation: presentation)
            buttons.showLayout()
            buttons.rename(title: "Rename Workspace…")
            buttons.newWorktree()
            Divider()
            buttons.close(title: "Close Workspace…", role: .destructive)
        }
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
        Button(title, systemImage: "pencil") {
            presentation.host = host
            presentation.sheet = .rename(workspaceID: target.workspaceID, label: target.label)
        }
        .tint(.gray)
        .disabled(isReadOnly)
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
                    buttons.rename(title: "Rename Workspace…")
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
            .confirmationDialog(
                closeTitle, isPresented: closeDialogShown, titleVisibility: .visible, presenting: presentation.closeRequest
            ) { request in
                Button("Close Workspace", role: .destructive) {
                    Task { await actions?.close(workspaceID: request.workspaceID, sessionIDs: request.sessionIDs) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Every tab, pane, and process in this workspace will stop. Transcripts stay on the host, but the agents stop running.")
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
                case .rename(let workspaceID, let label):
                    RenameWorkspaceSheet(actions: actions, workspaceID: workspaceID, original: label)
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

// MARK: - 重新命名

/// 依內容高度的表單(固定高度會被鍵盤蓋住,行為規格 F3.4)。預填 workspace 名稱(不是列標題)並全選。
struct RenameWorkspaceSheet: View {
    let actions: WorkspaceActionsModel
    let workspaceID: String
    let original: String
    @State private var label: String
    @State private var selection: TextSelection?
    /// 每次儲存的結果：成功與失敗各有觸覺回饋(行為規格 F3.4)。
    @State private var attempts: [Bool] = []
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(actions: WorkspaceActionsModel, workspaceID: String, original: String) {
        self.actions = actions
        self.workspaceID = workspaceID
        self.original = original
        _label = State(initialValue: original)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Workspace name", text: $label, selection: $selection)
                        .focused($focused)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("workspace.rename.field")
                } footer: {
                    Text("This renames the workspace on the host. herdr shows the new name too.")
                        .foregroundStyle(.secondaryText)
                }
                if let error = actions.renameError {
                    Section {
                        ErrorLabel(error)
                            .accessibilityIdentifier("workspace.rename.error")
                    }
                }
            }
            .navigationTitle("Rename Workspace")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!WorkspaceActionsModel.canRename(from: original, to: label) || actions.isWorking)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(trigger: attempts) { _, attempts in
            attempts.last.map { $0 ? .success : .error }
        }
        .onAppear {
            actions.clearRenameError()
            focused = true
            selection = TextSelection(range: label.startIndex..<label.endIndex)
        }
    }

    private func save() {
        guard WorkspaceActionsModel.canRename(from: original, to: label), !actions.isWorking else { return }
        Task {
            let renamed = await actions.rename(workspaceID: workspaceID, to: label)
            attempts.append(renamed)
            if renamed { dismiss() }
        }
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
