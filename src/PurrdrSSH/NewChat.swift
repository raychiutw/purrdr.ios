import Foundation
import PurrdrCore

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
    /// agent 就緒後送出的第一則訊息(#272);空白時不送。
    public var message: String
    /// 續接的 session id(#309);`nil` 是全新的聊天。續接時第一則訊息可以留空。
    public var resumeSession: String?

    public init(
        folder: String, label: String? = nil, agent: NewChatAgent, permissionMode: ClaudePermissionMode = .agentDefault, message: String = "",
        resumeSession: String? = nil
    ) {
        self.resumeSession = resumeSession
        self.folder = folder
        self.label = label
        self.agent = agent
        self.permissionMode = permissionMode
        self.message = message
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

/// 這台主機能不能續接過去的 session(#309)。
public enum ResumeSupport: Sendable, Equatable {
    case available
    /// SSH 主機:列出與續接都要主機服務。
    case needsHostService
    /// 主機服務版本不足(`installed` 是它回報的版本)。
    case updateRequired(installed: String?)
}

extension NewChatAgent {
    /// 主機服務能續接的 Agent(只有 Claude Code 與 Codex)。
    public var supportsResume: Bool { self == .claude || self == .codex }
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

    private let client: HerdrClient
    private let folders: NewChatFolders
    private let sleep: Sleep
    /// 上次建立、但 agent 還沒成功啟動的 workspace(與它的資料夾)。
    private var pending: (folder: String, workspace: CreatedWorkspace)?

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

    /// 這台主機能不能續接(#309):沒有主機服務(SSH)或版本不足都不能,畫面據此說明。
    /// 連不上主機時丟錯誤(不是「需要主機服務」),呼叫端說明並讓使用者重試。
    public func resumeSupport() async throws -> ResumeSupport {
        guard let version = try await client.hostServiceVersion() else { return .needsHostService }
        return HostServiceFeature.sessionResume.isAvailable(onHostServiceVersion: version) ? .available : .updateRequired(installed: version)
    }

    /// `folder` 過去的 session(新到舊;`~` 先在主機上解析)。只在 `resumeSupport() == .available` 時呼叫。
    public func resumableSessions(folder: String, agent: NewChatAgent) async throws -> [ResumableSession] {
        guard agent.supportsResume else { return [] }
        let resolved = try await folders.resolve(folder)
        return try await client.listSessions(cwd: resolved, agent: agent.rawValue)
    }

    /// 開始新對話，回傳新 workspace(聊天開在它的 root pane)與第一則訊息送了沒有。
    public func start(_ request: NewChatRequest) async throws -> NewChatStarted {
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
        let ready = try await startAgent(request, name: name, in: workspace)
        pending = nil
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !message.isEmpty else { return NewChatStarted(workspace: workspace, sentMessage: false) }
        // 不等 agent 開始工作：送出後聊天畫面自己跟上(送不到時丟錯誤，不重送，§7.3)。
        _ = try await client.prompt(target: workspace.rootPaneID, text: message, wait: nil)
        return NewChatStarted(workspace: workspace, sentMessage: true)
    }

    /// 啟動 agent;回傳它是否已就緒(停在啟動問題時是 `false`)。
    private func startAgent(_ request: NewChatRequest, name: String, in workspace: CreatedWorkspace) async throws -> Bool {
        var retries = 0
        while true {
            do {
                try await client.startAgent(
                    name: name, kind: request.agent.rawValue, paneID: workspace.rootPaneID,
                    arguments: request.agentArguments, resumeSession: request.resumeSession, timeout: Self.agentTimeout)
                return true
            } catch HerdrError.herdr(code: "agent_not_ready", _) {
                // agent 已經起來，但停在啟動問題(例如資料夾信任):在聊天裡回答。
                return false
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
