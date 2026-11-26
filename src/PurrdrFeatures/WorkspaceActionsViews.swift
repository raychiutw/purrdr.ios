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

        var id: String {
            switch self {
            case .worktree(let id, _): "worktree.\(id)"
            }
        }
    }

    struct CloseRequest {
        var workspaceID: String
        var label: String
        var sessionIDs: [String]
    }

    var sheet: Sheet?
    /// 選單「Show Layout」要推入的版面圖(#619):一次性的要求,presenter 轉成導覽路徑後清成 `nil`(#641)。
    var layoutRoute: SpacesLayoutRoute?
    /// 重新命名提示框(#456):Workspace 與 Tab 共用,系統帶輸入框的 alert。
    var renameRequest: RenameRequest?
    /// 提示框裡的輸入;失敗後重新呈現時保留。
    var renameText = ""
    /// 上一次送出失敗的原因(重新呈現的提示框顯示)。
    var renameFailure: String?
    var closeRequest: CloseRequest?
    /// 關閉 Tab 的確認(#534)。
    var closeTabRequest: TabTarget?
    /// 操作的是哪台主機(多主機合併列表，#39)。列設定 sheet 或確認時一併設定。
    var host: HostSelection = .demo
    /// 版面圖裡點選的 Pane:先記下、返回上一頁之後才開(不能在返回的同一刻 push,行為規格 F4)。
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
    /// 這個 Tab 底下所有 Agent 的 session(關閉時一併清掉本機偏好)。
    var sessionIDs: [String]
    /// 是所屬 Workspace 唯一的 Tab。
    var isLastInWorkspace: Bool

    init?(tabID: String?, snapshot: HostSnapshot?, workspaceLabel: String) {
        guard let tabID, let snapshot, let tab = snapshot.tabs.first(where: { $0.id == tabID }) else { return nil }
        self.tabID = tabID
        label = tab.label ?? String(tab.number)
        self.workspaceLabel = workspaceLabel
        sessionIDs = snapshot.agents.filter { $0.tabID == tabID }.compactMap(\.sessionID)
        isLastInWorkspace = !snapshot.tabs.contains { $0.workspaceID == tab.workspaceID && $0.id != tabID }
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
    /// Spaces 檢視 Tab 列的 context menu(#275、#491 補回釘選與靜音):最前面是「在新視窗開啟」(支援多視窗時)與釘選、靜音,
    /// 接著版面圖，其餘同列的 workspace 動作。
    ///
    /// Tab 可能有多個 Agent:釘選與靜音作用在底下所有 Agent 的聊天(`sessionIDs`,沒有 session 時不顯示)。
    /// 改名改的是這個 Tab;Workspace 名稱在段落標題的長按選單(`workspaceHeaderMenu`,#456)。`tab` 為 nil(沒有 Tab 的 pane)時沒有改名項目。
    func workspaceActionsMenu(
        _ target: WorkspaceTarget, tab: TabTarget?, host: HostSelection, snapshot: HostSnapshot?, presentation: WorkspacePresentation,
        chats: TabChatActions? = nil, openInNewWindow: (() -> Void)? = nil, actions: WorkspaceActionsModel? = nil
    ) -> some View {
        modifier(CloseTabDialog(presentation: presentation, tab: tab, actions: actions))
        .contextMenu {
            let buttons = WorkspaceButtons(target: target, host: host, snapshot: snapshot, presentation: presentation)
            let level = WorkspaceMenuLevel.tab(hasNewWindow: openInNewWindow != nil, hasChats: chats != nil, hasTab: tab != nil)
            // 項目由 `WorkspaceMenuLevel` 一處決定(#536);「版面圖」前的分隔線只在前面有新視窗或釘選靜音時出現。
            ForEach(level.entries, id: \.self) { entry in
                if entry == .showLayout, openInNewWindow != nil || chats != nil { Divider() }
                buttons.view(for: entry, tab: tab, chats: chats, openInNewWindow: openInNewWindow)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let tab {
                WorkspaceButtons(target: target, host: host, snapshot: snapshot, presentation: presentation)
                    .closeTab(tab, inSwipe: true)
            }
        }
    }

    /// Spaces 檢視段落標題的長按選單(#456):List 的段落標題掛不上 `contextMenu`，
    /// 所以標題本身是 `Menu`(輕點不做事、長按出選單):重新命名 Workspace…、版面圖、新 worktree、關閉。
    /// VoiceOver 另有「重新命名 Workspace…」自訂動作。唯讀裝置的改動項目停用。
    func workspaceHeaderMenu(
        _ target: WorkspaceTarget, host: HostSelection, snapshot: HostSnapshot?, isReadOnly: Bool, presentation: WorkspacePresentation,
        newChatHere: (() -> Void)? = nil, actions: WorkspaceActionsModel? = nil
    ) -> some View {
        let buttons = WorkspaceButtons(target: target, host: host, snapshot: snapshot, presentation: presentation, isReadOnly: isReadOnly)
        return Menu {
            ForEach(WorkspaceMenuLevel.workspace(canStartChat: newChatHere != nil).entries, id: \.self) { entry in
                if entry == .closeWorkspace { Divider() }
                buttons.view(for: entry, tab: nil, chats: nil, openInNewWindow: nil, newChatHere: newChatHere)
            }
            if isReadOnly { Text(WorkspaceActionsModel.readOnlyMessage) }
        } label: {
            self
        } primaryAction: {}
        .modifier(CloseWorkspaceDialog(presentation: presentation, target: target, actions: actions))
        .buttonStyle(HeaderPressStyle())
        .accessibilityHint(Text("Double-tap and hold to show Workspace actions"))
        .accessibilityAction(named: Text("Rename Workspace…")) { if !isReadOnly { buttons.askWorkspaceName() } }
    }

    /// 呈現 workspace 操作的 sheet、確認與錯誤。`actions` 依主機取得該主機的操作;
    /// `onOpen` 在版面圖選了 Pane 且 sheet 關閉之後呼叫(帶主機)。
    func workspaceActionsPresentation(
        actions: @escaping (HostSelection) -> WorkspaceActionsModel?, snapshot: @escaping (HostSelection) -> HostSnapshot?,
        presentation: WorkspacePresentation, path: Binding<[ChatsDestination]>,
        showLayoutInDetail: ((SpacesLayoutRoute) -> Void)? = nil,
        chatDestination: @escaping (ChatRoute) -> AnyView, onOpen: @escaping (HostSelection, PaneOpenTarget) -> Void
    ) -> some View {
        modifier(WorkspaceActionsPresenter(
            resolve: actions, snapshot: snapshot, presentation: presentation, path: path, showLayoutInDetail: showLayoutInDetail, chatDestination: chatDestination,
            onOpen: onOpen))
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

    /// 依選單項目(`WorkspaceMenuEntry`)給對應的按鈕。
    @ViewBuilder
    func view(
        for entry: WorkspaceMenuEntry, tab: TabTarget?, chats: TabChatActions?, openInNewWindow: (() -> Void)?,
        newChatHere: (() -> Void)? = nil
    ) -> some View {
        switch entry {
        case .openInNewWindow:
            if let openInNewWindow {
                Button("Open in New Window", systemImage: "macwindow.badge.plus", action: openInNewWindow)
                    .accessibilityIdentifier("menu.openInNewWindow")
            }
        case .pin:
            if let chats {
                let pinned = chats.actions.arePinned(sessionIDs: chats.sessionIDs)
                Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                    chats.actions.togglePin(sessionIDs: chats.sessionIDs)
                }
                .accessibilityIdentifier("menu.pin")
            }
        case .mute:
            if let chats {
                let muted = chats.actions.areMuted(sessionIDs: chats.sessionIDs)
                Button(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash") {
                    chats.actions.toggleMute(sessionIDs: chats.sessionIDs)
                }
                .accessibilityIdentifier("menu.mute")
            }
        case .showLayout: showLayout()
        case .renameTab: if let tab { renameTab(tab, showsCurrent: false) }
        case .closeTab: if let tab { closeTab(tab) }
        case .newChatHere:
            if let newChatHere {
                Button("New Chat Here", systemImage: "plus.bubble", action: newChatHere)
                    .accessibilityIdentifier("menu.newChatHere")
                    .disabled(isReadOnly)
            }
        case .renameWorkspace: renameWorkspace(showsCurrent: true)
        case .newWorktree: newWorktree()
        case .closeWorkspace: close(title: "Close Workspace…", role: .destructive)
        }
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

    /// 「關閉 Tab…」(#534):選單與左滑共用,先經確認。
    /// 左滑(`inSwipe`)時不標 destructive:List 的左滑按鈕標 destructive 會先自己刪掉那一列,
    /// 但這裡要等確認、主機真的關掉才少一列;中間任何一次列表更新都會讓 UICollectionView 列數對不上而中止 app(0.52.1)。
    /// 改用紅色外觀表示破壞性。選單裡維持 destructive(選單不會刪列)。
    func closeTab(_ tab: TabTarget, inSwipe: Bool = false) -> some View {
        Button("Close Tab…", systemImage: "xmark", role: inSwipe ? nil : .destructive) {
            presentation.host = host
            presentation.closeTabRequest = tab
        }
        .tint(inSwipe ? .red : nil)
        .accessibilityIdentifier("menu.closeTab")
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
            // 版面在推入當下取 snapshot,不即時更新(行為規格 F4)。
            presentation.host = host
            presentation.layoutRoute = SpacesLayoutRoute(host: host, workspaceID: target.workspaceID, tabID: nil, title: target.label)
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

/// Workspace 標題長按的觸覺時機(#547):觸覺要在選單出現時才給,不是按下就給。
/// 選單一出現,系統就接手觸控、按壓結束;所以按壓持續超過長按門檻才結束,就當作選單出現了(短按放開不算)。
enum WorkspaceHeaderHaptic {
    /// 系統長按叫出選單的大約時間,略取小一點以免漏掉。
    static let menuAppearDelay: TimeInterval = 0.35

    static func menuAppeared(afterPressLasting duration: TimeInterval) -> Bool {
        duration >= menuAppearDelay
    }
}

/// Workspace 段落標題(`Menu`)的按下反饋(#536):按住時淡灰底高亮;選單出現時輕觸覺(#547)。
private struct HeaderPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeaderPressBody(configuration: configuration)
    }
}

private struct HeaderPressBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var pressStart: Date?
    @State private var menuAppearances = 0

    var body: some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.12) : Color.clear)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    pressStart = Date()
                } else if let start = pressStart {
                    pressStart = nil
                    if WorkspaceHeaderHaptic.menuAppeared(afterPressLasting: Date().timeIntervalSince(start)) { menuAppearances += 1 }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: menuAppearances)
    }
}

private struct WorkspaceActionsPresenter: ViewModifier {
    let resolve: (HostSelection) -> WorkspaceActionsModel?
    let snapshot: (HostSelection) -> HostSnapshot?
    @Bindable var presentation: WorkspacePresentation
    @Binding var path: [ChatsDestination]
    /// 寬視窗:版面圖顯示在對話欄(列表欄的選取),不進路徑。
    let showLayoutInDetail: ((SpacesLayoutRoute) -> Void)?
    /// 路徑上聊天目的地的畫面(窄視窗才有聊天進路徑;寬視窗給空畫面)。
    let chatDestination: (ChatRoute) -> AnyView
    let onOpen: (HostSelection, PaneOpenTarget) -> Void

    /// 目前操作的主機的 Workspace 操作。
    private var actions: WorkspaceActionsModel? { resolve(presentation.host) }

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentation.sheet, onDismiss: openChosenTarget) { sheet in
                if let actions { sheetContent(sheet, actions: actions) }
            }
            // 整個聊天 tab 的堆疊只在這裡註冊一次目的地(#641):聊天與版面圖都以 `ChatsDestination` 進路徑。
            // Tab 列是 `NavigationLink(value:)`;選單的「Show Layout」設 `layoutRoute`,在這裡轉成路徑上的一筆。
            .navigationDestination(for: ChatsDestination.self) { destination in
                switch destination {
                case .chat(let route): chatDestination(route)
                case .layout(let route): layoutDestination(route)
                }
            }
            .onChange(of: presentation.layoutRoute) { _, route in
                guard let route else { return }
                presentation.layoutRoute = nil
                if let showLayoutInDetail { showLayoutInDetail(route) } else { path.append(.layout(route)) }
            }
            .alert(renameTitle, isPresented: renameShown, presenting: presentation.renameRequest) { request in
                TextField(renamePlaceholder(request), text: $presentation.renameText)
                    .inputFieldTint()
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Rename") { submitRename(request) }
                    .disabled(!WorkspaceActionsModel.canRename(from: request.original, to: presentation.renameText))
            } message: { request in
                Text(renameMessage(request))
            }
            .alert(Text(verbatim: actions?.actionErrorTitle ?? ""), isPresented: errorShown, presenting: actions?.actionError) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.text)
            }
            .reportsErrorDisplay(actions?.actionError, area: "WorkspaceActions")
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WorkspacePresentation.Sheet, actions: WorkspaceActionsModel) -> some View {
                switch sheet {
                case .worktree(let workspaceID, let label):
                    NewWorktreeSheet(actions: actions, workspaceID: workspaceID, workspaceLabel: label) { created in
                        presentation.chosenTarget = .terminal(paneID: created.rootPaneID)
                    }
                }
    }

    private func layoutDestination(_ route: SpacesLayoutRoute) -> some View {
        SpacesLayoutDestination(route: route, snapshot: snapshot(route.host)) { host, target in
            presentation.host = host
            presentation.chosenTarget = target
        }
        // 返回上一頁之後才開選到的 Pane(不能在返回的同一刻 push)。
        .onDisappear { openChosenTargetAfterPop() }
    }

    private func openChosenTargetAfterPop() {
        guard presentation.chosenTarget != nil else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            openChosenTarget()
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
                        .inputFieldTint()
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
                        ErrorLabel(error.text, area: "WorkspaceActionsViews", error: error.descriptor)
                            .accessibilityIdentifier("workspace.worktree.error")
                    }
                }
            }
            .appSheetList()
            .navigationTitle("New Worktree")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                SheetCloseToolbar()
                ModalConfirmToolbar(
                    title: actions.isWorking ? "Creating…" : "Create", identifier: "workspace.worktree.create",
                    isEnabled: canCreate, action: create)
            }
        }
        .appSheet(detents: [.medium, .large])
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

/// 關閉 Workspace 的確認(#625):掛在觸發的段落標題上,錨定在標題;只有發出請求的那個 Workspace 的標題顯示。
private struct CloseWorkspaceDialog: ViewModifier {
    @Bindable var presentation: WorkspacePresentation
    let target: WorkspaceTarget
    let actions: WorkspaceActionsModel?

    func body(content: Content) -> some View {
        // confirmationDialog:anchor 由段落標題的長按選單觸發,對話框錨定在那個標題
        content.confirmationDialog(
            Text("Close “\(presentation.closeRequest?.label ?? "")”?"),
            isPresented: Binding(
                get: { presentation.closeRequest?.workspaceID == target.workspaceID },
                set: { if !$0, presentation.closeRequest?.workspaceID == target.workspaceID { presentation.closeRequest = nil } }),
            titleVisibility: .visible, presenting: presentation.closeRequest
        ) { request in
            Button("Close Workspace", role: .destructive) {
                Task { await actions?.close(workspaceID: request.workspaceID, sessionIDs: request.sessionIDs) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Everything running in this workspace will stop, including its agents. Chat history stays on the host.")
        }
    }
}

/// 關閉 Tab 的確認(#534、#625):掛在觸發的 Tab 列上,錨定在那一列。
private struct CloseTabDialog: ViewModifier {
    @Bindable var presentation: WorkspacePresentation
    let tab: TabTarget?
    let actions: WorkspaceActionsModel?

    func body(content: Content) -> some View {
        // confirmationDialog:anchor 由 Tab 列的長按選單或左滑觸發,對話框錨定在那一列
        content.confirmationDialog(
            Text("Close tab “\(presentation.closeTabRequest?.label ?? "")”?"),
            isPresented: Binding(
                get: { tab != nil && presentation.closeTabRequest?.tabID == tab?.tabID },
                set: { if !$0, presentation.closeTabRequest?.tabID == tab?.tabID { presentation.closeTabRequest = nil } }),
            titleVisibility: .visible, presenting: presentation.closeTabRequest
        ) { request in
            Button(request.isLastInWorkspace ? "Close Tab and Workspace" : "Close Tab", role: .destructive) {
                Task { await actions?.closeTab(tabID: request.tabID, sessionIDs: request.sessionIDs) }
            }
            .accessibilityIdentifier("closeTab.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("closeTab.cancel")
        } message: { request in
            if request.isLastInWorkspace {
                Text("This is the last tab in “\(request.workspaceLabel)”, so the workspace closes too. Everything running in it will stop, including its agents. Chat history stays on the host.")
            } else {
                Text("Everything running in this tab will stop, including its agents. Chat history stays on the host.")
            }
        }
    }
}
