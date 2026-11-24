import Foundation
import PurrdrCore

/// Claude Code 的權限模式(`claude --permission-mode`)。只有 Claude Code 有。
///
/// 預設是 `agentDefault`:**不帶** `--permission-mode`,沿用使用者在主機上給 Claude Code 的設定。
/// 不預設成 `bypassPermissions`(完全不詢問):從手機開一個不會停下來問的 agent 必須是使用者明確的選擇(#18)。
public enum ClaudePermissionMode: String, CaseIterable, Sendable {
    /// 不帶參數，沿用 agent 自己的設定。
    case agentDefault
    case manual
    case acceptEdits
    case plan
    case auto
    case bypassPermissions
}

/// 新聊天放在哪裡(#537)。
public enum NewChatTarget: Sendable, Equatable {
    /// 在 `folder` 建立新的 Workspace(預設)。
    case newWorkspace
    /// 在既有 Workspace 裡新增一個 Tab;資料夾沿用它的工作目錄(`NewChatRequest.folder` 是畫面顯示的那一個)。
    case existingWorkspace(id: String)
}

/// 主機上目前開著的 Workspace(新增聊天「既有的 Workspace」的選項,#537)。
public struct ExistingWorkspace: Sendable, Equatable, Identifiable {
    public var id: String
    /// herdr 的 Workspace 名稱;沒有時是 `nil`(畫面不露內部 id,改顯示白話文字)。
    public var name: String?
    /// herdr 回報的工作目錄(第一個 Tab 的 pane);不知道時為 `nil`。
    public var folder: String?

    public init(id: String, name: String?, folder: String?) {
        self.id = id
        self.name = name
        self.folder = folder
    }
}

/// 新增對話的內容。
public struct NewChatRequest: Sendable, Equatable {
    /// 使用者給的資料夾(可以是 `~/…`);開始前在主機上解析成絕對路徑。
    public var folder: String
    /// workspace 名稱;`nil` 時由 herdr 命名(資料夾名)。
    public var label: String?
    /// 第一個 tab 的名稱(#532);`nil` 時沿用 herdr 的預設。
    public var tabLabel: String?
    /// 啟動的種類(`AgentCatalog.startableAgents`);herdr 的 kind 是它的正式名稱。
    public var agent: AgentID
    /// 只有 Claude Code 會用到。
    public var permissionMode: ClaudePermissionMode
    /// agent 就緒後送出的第一則訊息(#272);空白時不送。
    public var message: String
    /// 續接的 session id(#309);`nil` 是全新的聊天。續接時第一則訊息可以留空。
    public var resumeSession: String?
    /// 接續最近一次對話(Antigravity 的 `-c`,#446);沒有這個旗標的種類忽略。
    public var continuesLastSession: Bool
    /// 放在新的還是既有的 Workspace(#537)。
    public var target: NewChatTarget

    public init(
        folder: String, label: String? = nil, tabLabel: String? = nil, agent: AgentID, permissionMode: ClaudePermissionMode = .agentDefault, message: String = "",
        resumeSession: String? = nil, continuesLastSession: Bool = false, target: NewChatTarget = .newWorkspace
    ) {
        self.target = target
        self.resumeSession = resumeSession
        self.continuesLastSession = continuesLastSession
        self.folder = folder
        self.label = label
        self.tabLabel = tabLabel
        self.agent = agent
        self.permissionMode = permissionMode
        self.message = message
    }

    /// 交給 agent 的參數(`herdr agent start … -- <參數>`)。設定檔的啟動參數一律先帶(Codex 的 `--no-daemon`,#400);權限模式只給設定檔有旗標的種類(Claude Code),而且只在使用者選了的時候;
    /// 恢復對話(`--conversation <id>`)與接續最近一次(`-c`)只給設定檔有旗標的種類(Antigravity,#446)。
    public var agentArguments: [String] {
        let session = AgentCatalog.profile(for: agent).session
        var arguments = session.launchArguments
        if let flag = session.permissionModeFlag, permissionMode != .agentDefault { arguments += [flag, permissionMode.rawValue] }
        else if let flag = session.resumeConversationFlag, let resumeSession { arguments += [flag, resumeSession] }
        else if let flag = session.continueFlag, continuesLastSession { arguments += [flag] }
        return arguments
    }

    /// herdr 的 agent 名稱：workspace 名稱的 slug(桌機的 `herdr agent list` 看到同名,行為規格 F3.2)。
    /// NFKD 後去掉組合符號、小寫、非英數合成 `-`、頭尾修剪、最長 40 字;剩下空的用 `chat`。
    public static func agentName(for label: String) -> String {
        let folded = label.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !$0.properties.isDiacritic && $0.properties.generalCategory != .nonspacingMark }
        var slug = ""
        var pendingDash = false
        for scalar in folded {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !slug.isEmpty { slug += "-" }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        slug = String(slug.lowercased().prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "chat" : slug
    }
}

/// 這台主機能不能續接過去的 session(#309)。
public enum ResumeSupport: Sendable, Equatable {
    case available
    /// 主機服務版本不足(`installed` 是它回報的版本)。
    case updateRequired(installed: String?)
}

/// 新對話開始的結果。
public struct NewChatStarted: Sendable, Equatable {
    public var workspace: CreatedWorkspace
    /// 第一則訊息已經送出;agent 停在啟動問題(例如資料夾信任)時沒送，留給聊天的輸入框。
    public var sentMessage: Bool

    public init(workspace: CreatedWorkspace, sentMessage: Bool) {
        self.workspace = workspace
        self.sentMessage = sentMessage
    }
}

/// 開始新對話(行為規格 F3.2):在主機上解析資料夾 → 建立 workspace → 在它的 root pane 啟動 agent → 送出第一則訊息(#272)。
///
/// 重試語意：啟動失敗後再按一次，若資料夾相同就沿用上次建立的 workspace、只重跑啟動;資料夾換了先盡力關掉上次的
/// workspace(不留孤兒)再新建。
public actor NewChatLauncher {
    /// herdr 等 agent 就緒的時間。
    public static let agentTimeout: Duration = .seconds(60)
    /// `agent_pane_busy`(pane 的 shell 還沒到提示字元)的重試次數與間隔。只有這個碼可以重試：
    /// 其他失敗(例如逾時)可能代表 agent 其實已經啟動。
    static let busyRetries = 4
    static let busyRetryInterval: Duration = .milliseconds(750)

    /// `launch_pending` 後輪詢就緒:500ms 一次、最多 40 次(約 20 秒)。
    static let pollInterval: Duration = .milliseconds(500)
    static let pollAttempts = 40

    private let client: HerdrClient
    private let folders: NewChatFolders
    private let sleep: Sleep
    /// 上次建立、但 agent 還沒成功啟動的 workspace(與它的資料夾),或在既有 workspace 新建的 tab(#537)。
    private enum Pending {
        case workspace(folder: String, CreatedWorkspace)
        case tab(CreatedTab)
    }

    private var pending: Pending?

    public init(
        client: HerdrClient, folders: NewChatFolders,
        sleep: @escaping Sleep = Sleeping.task
    ) {
        self.client = client
        self.folders = folders
        self.sleep = sleep
    }

    /// 這支裝置是否配對成唯讀(HTTPS 主機;唯讀時不能新增聊天)。讀不到算不是。
    public func isReadOnlyDevice() async -> Bool {
        (try? await client.isReadOnlyDevice()) == true
    }

    /// 這台主機能不能續接(#309、#535):SSH 主機(沒有主機服務)由連線層以腳本列出並續接,所以一律可以;
    /// 主機服務版本不足才不能,畫面據此說明並附更新指令。
    /// 連不上主機時丟錯誤,呼叫端說明並讓使用者重試。
    public func resumeSupport() async throws -> ResumeSupport {
        guard let version = try await client.hostServiceVersion() else { return .available }
        return HostServiceFeature.sessionResume.isAvailable(onHostServiceVersion: version) ? .available : .updateRequired(installed: version)
    }

    /// `folder` 過去的 session(新到舊;`~` 先在主機上解析)。只在 `resumeSupport() == .available` 時呼叫。
    public func resumableSessions(folder: String, agent: AgentID) async throws -> [ResumableSession] {
        guard let kind = AgentCatalog.profile(for: agent).session.resumeKind else { return [] }
        let resolved = try await folders.resolve(folder)
        return try await client.listSessions(cwd: resolved, agent: kind)
    }

    /// 主機上目前開著的 Workspace(依主機順序)。
    public func existingWorkspaces() async throws -> [ExistingWorkspace] {
        let snapshot = try await client.snapshot()
        return snapshot.workspaces.sorted { $0.number < $1.number }.map { workspace in
            // herdr 沒有 workspace 的工作目錄欄位:取第一個 Tab(編號最小)的 pane,沒有就取 workspace 裡任何一個 pane。
            let firstTab = snapshot.tabs.filter { $0.workspaceID == workspace.id }.min { $0.number < $1.number }
            let panes = snapshot.panes.filter { $0.workspaceID == workspace.id }
            let pane = panes.first { $0.tabID == firstTab?.id && $0.cwd != nil } ?? panes.first { $0.cwd != nil }
            // 沒有名稱時退回工作目錄的最後一段;兩者都沒有就是 `nil`,不回報內部 id。
            let name = workspace.label.flatMap { $0.isEmpty ? nil : $0 }
                ?? pane?.cwd.flatMap { HostPathSyntax.lastComponent($0).map(String.init) }.flatMap { $0.isEmpty ? nil : $0 }
            return ExistingWorkspace(id: workspace.id, name: name, folder: pane?.cwd)
        }
    }

    /// 開始新對話，回傳新 workspace(聊天開在它的 root pane)與第一則訊息送了沒有。
    public func start(_ request: NewChatRequest) async throws -> NewChatStarted {
        let workspace: CreatedWorkspace
        let name: String
        switch request.target {
        case .newWorkspace:
            let folder = try await folders.resolve(request.folder)
            if case .workspace(let pendingFolder, let created)? = pending, pendingFolder == folder {
                workspace = created
            } else {
                await discardPending()
                workspace = try await client.createWorkspace(cwd: folder, label: request.label, tabLabel: request.tabLabel)
                pending = .workspace(folder: folder, workspace)
            }
            name = NewChatRequest.agentName(for: request.label ?? Self.lastComponent(of: folder))
        case .existingWorkspace(let id):
            // 工作目錄沿用 Workspace 的(herdr 回報的 cwd),不必在主機上解析。
            let tab: CreatedTab
            if case .tab(let created)? = pending, created.workspaceID == id {
                tab = created
            } else {
                await discardPending()
                tab = try await client.createTab(in: id, label: request.tabLabel)
                pending = .tab(tab)
            }
            workspace = CreatedWorkspace(workspaceID: tab.workspaceID, rootPaneID: tab.rootPaneID)
            name = Self.agentName(forTab: tab, label: request.tabLabel, folder: request.folder)
        }
        let outcome = try await startAgent(request, name: name, in: workspace)
        // agent 已經啟動(不論是否就緒):不再是「建了卻沒啟動」的殘留,重試不該關掉或重建它。
        pending = nil
        var ready = outcome == .ready
        // HTTPS 主機服務已在主機端等過 agent 就緒(`launch_pending` 是等完的結果),不再輪詢 `agent.get`(那是 herdr 0.9.5 socket 的做法)。
        if outcome == .launchPending, try await client.hostServiceVersion() == nil {
            ready = try await waitUntilInteractive(workspace.rootPaneID)
        }
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !message.isEmpty else { return NewChatStarted(workspace: workspace, sentMessage: false) }
        // 不等 agent 開始工作：送出後聊天畫面自己跟上(送不到時丟錯誤，不重送，§7.3)。
        do {
            _ = try await client.prompt(target: workspace.rootPaneID, text: message, wait: nil)
        } catch HerdrError.herdr(code: "agent_not_ready", _), HerdrError.herdr(code: "agent_blocked", _) {
            // agent 還沒就緒(herdr:agent … is not an active named agent)或停在問題上:什麼都沒送出，訊息留給聊天輸入框。
            return NewChatStarted(workspace: workspace, sentMessage: false)
        }
        return NewChatStarted(workspace: workspace, sentMessage: true)
    }

    /// 盡力關掉上次建立、但 agent 沒成功啟動的東西(不留孤兒):新 Workspace 用 `workspace.close`,新 Tab 用 `tab.close`。
    /// 只會關掉自己建立的,絕不碰使用者原本就有的 Workspace。
    private func discardPending() async {
        guard let previous = pending else { return }
        pending = nil
        switch previous {
        case .workspace(_, let workspace): try? await client.closeWorkspace(workspace.workspaceID)
        case .tab(let tab): try? await client.closeTab(tab.tabID)
        }
    }

    /// 既有 Workspace 的新 Tab:agent 名稱在 herdr 的活著的 agent 裡要唯一([a-z][a-z0-9_-]{0,31}),
    /// 所以 Workspace 裡原本的 agent 可能已經用了資料夾名,這裡加上 Tab 編號(`t3`)。
    private static func agentName(forTab tab: CreatedTab, label: String?, folder: String) -> String {
        var base = String(NewChatRequest.agentName(for: label ?? lastComponent(of: folder)).prefix(27))
        while base.hasSuffix("-") { base.removeLast() }
        let suffix = tab.tabID.split(separator: ":").last.map(String.init) ?? "tab"
        return "\(base)-\(suffix)"
    }

    /// `startAgent` 的結果。
    private enum StartOutcome: Equatable {
        /// 已就緒。
        case ready
        /// `launch_pending`:agent 還在啟動(才值得輪詢)。
        case launchPending
        /// `agent_not_ready`:停在啟動問題,不輪詢。
        case notReady
    }

    /// `agent.start` 回 `launch_pending` 後,每 500ms 以 `agent.get` 輪詢最多約 20 秒(herdr 0.9.5 的 socket 一律立刻回 pending)。
    /// 就緒回 `true`;`blocked`(停在資料夾信任等)、逾時或輪詢出錯回 `false`——agent 已經啟動,
    /// 輪詢失敗不是啟動失敗,訊息留給聊天輸入框。取消照常丟出。
    private func waitUntilInteractive(_ paneID: String) async throws -> Bool {
        for _ in 0..<Self.pollAttempts {
            do {
                try await sleep(Self.pollInterval)
                let state = try await client.agentLaunchState(target: paneID)
                if state.isReady { return true }
                if state.isBlocked { return false }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return false
            }
        }
        return false
    }

    /// 啟動 agent;回傳啟動結果(停在啟動問題時不是 `.ready`)。
    private func startAgent(_ request: NewChatRequest, name: String, in workspace: CreatedWorkspace) async throws -> StartOutcome {
        var retries = 0
        while true {
            do {
                // launch_pending:agent 還在啟動(例如停在資料夾信任問題),視同還沒就緒。
                let ready = try await client.startAgent(
                    name: name, kind: request.agent.canonicalName, paneID: workspace.rootPaneID,
                    arguments: request.agentArguments, resumeSession: Self.hostServiceResumeSession(for: request), timeout: Self.agentTimeout)
                return ready ? .ready : .launchPending
            } catch HerdrError.herdr(code: "agent_not_ready", _) {
                // agent 已經起來，但停在啟動問題(例如資料夾信任):在聊天裡回答。
                return .notReady
            } catch HerdrError.herdr(code: "agent_pane_busy", let message) {
                guard retries < Self.busyRetries else { throw HerdrError.herdr(code: "agent_pane_busy", message: message) }
                retries += 1
                try await sleep(Self.busyRetryInterval)
            }
        }
    }

    /// `resume_session` 只給能恢復的種類(Claude Code、Codex);主機服務(HTTPS)直接收這個欄位,SSH 連線層換成 `args` 的續接參數(#535)。旗標式恢復(Antigravity)已經放在 args。
    private static func hostServiceResumeSession(for request: NewChatRequest) -> String? {
        AgentCatalog.profile(for: request.agent).session.resumeKind == nil ? nil : request.resumeSession
    }

    private static func lastComponent(of path: String) -> String {
        HostPathSyntax.lastComponent(path).map(String.init) ?? ""
    }
}
