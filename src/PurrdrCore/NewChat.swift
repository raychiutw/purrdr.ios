import Foundation

/// 新增對話可以啟動的 agent(行為規格 F3.1)。`rawValue` 是 herdr 的 kind(`herdr agent start --kind`)。
public enum NewChatAgent: String, CaseIterable, Sendable {
    case claude
    case codex
    case grok
    /// Antigravity。
    case agy
    case pi
    case omp
}

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

/// 新增對話的內容。
public struct NewChatRequest: Sendable, Equatable {
    /// 使用者給的資料夾(可以是 `~/…`);開始前在主機上解析成絕對路徑。
    public var folder: String
    /// workspace 名稱;`nil` 時由 herdr 命名(資料夾名)。
    public var label: String?
    public var agent: NewChatAgent
    /// 只有 Claude Code 會用到。
    public var permissionMode: ClaudePermissionMode

    public init(folder: String, label: String? = nil, agent: NewChatAgent, permissionMode: ClaudePermissionMode = .agentDefault) {
        self.folder = folder
        self.label = label
        self.agent = agent
        self.permissionMode = permissionMode
    }

    /// 交給 agent 的參數(`herdr agent start … -- <參數>`)。權限模式只給 Claude Code,而且只在使用者選了的時候。
    public var agentArguments: [String] {
        guard agent == .claude, permissionMode != .agentDefault else { return [] }
        return ["--permission-mode", permissionMode.rawValue]
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

/// 開始新對話(行為規格 F3.2):在主機上解析資料夾 → 建立 workspace → 在它的 root pane 啟動 agent。
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

    private let client: HerdrClient
    private let folders: NewChatFolders
    private let sleep: @Sendable (Duration) async throws -> Void
    /// 上次建立、但 agent 還沒成功啟動的 workspace(與它的資料夾)。
    private var pending: (folder: String, workspace: CreatedWorkspace)?

    public init(
        client: HerdrClient, folders: NewChatFolders,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.folders = folders
        self.sleep = sleep
    }

    /// 開始新對話，回傳新 workspace(聊天開在它的 root pane)。
    public func start(_ request: NewChatRequest) async throws -> CreatedWorkspace {
        let folder = try await folders.resolve(request.folder)
        let workspace: CreatedWorkspace
        if let pending, pending.folder == folder {
            workspace = pending.workspace
        } else {
            if let pending {
                self.pending = nil
                try? await client.closeWorkspace(pending.workspace.workspaceID)
            }
            workspace = try await client.createWorkspace(cwd: folder, label: request.label)
            pending = (folder, workspace)
        }
        let name = NewChatRequest.agentName(for: request.label ?? Self.lastComponent(of: folder))
        try await startAgent(request, name: name, in: workspace)
        pending = nil
        return workspace
    }

    private func startAgent(_ request: NewChatRequest, name: String, in workspace: CreatedWorkspace) async throws {
        var retries = 0
        while true {
            do {
                try await client.startAgent(
                    name: name, kind: request.agent.rawValue, paneID: workspace.rootPaneID,
                    arguments: request.agentArguments, timeout: Self.agentTimeout)
                return
            } catch HerdrError.herdr(code: "agent_not_ready", _) {
                // agent 已經起來，但停在啟動問題(例如資料夾信任):在聊天裡回答。
                return
            } catch HerdrError.herdr(code: "agent_pane_busy", let message) {
                guard retries < Self.busyRetries else { throw HerdrError.herdr(code: "agent_pane_busy", message: message) }
                retries += 1
                try await sleep(Self.busyRetryInterval)
            }
        }
    }

    private static func lastComponent(of path: String) -> String {
        HostPathSyntax.lastComponent(path).map(String.init) ?? ""
    }
}
