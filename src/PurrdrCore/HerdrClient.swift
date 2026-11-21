import Foundation

/// 經主機連線呼叫 herdr socket API 的 client。wire format(snake_case)只在這個檔案處理。
///
/// 每個單次請求都有期限(#86):沒有等待參數的是 `HostCommandDeadline.standard`(20 秒),
/// 有等待參數的(`prompt`、`waitForAgent`、`startAgent`、`createWorkspace`)見各自的說明。
public struct HerdrClient: Sendable {
    private let connection: any HostConnection

    public init(connection: any HostConnection) {
        self.connection = connection
    }

    /// 這支裝置是否配對成唯讀(HTTPS 連線方式;唯讀時送 prompt、文字與按鍵都會被拒絕)。
    public func hostServiceVersion() async throws -> String? {
        try await connection.hostServiceVersion()
    }

    public func isReadOnlyDevice() async throws -> Bool {
        try await connection.isReadOnlyDevice()
    }

    /// 關掉底層連線(卡住的請求跟著失敗);下一個請求重新連線。
    public func disconnect() async {
        await connection.disconnect()
    }

    /// 開始快速偵測斷線(聊天畫面可見時)。
    public func beginQuickDisconnectDetection() async {
        await connection.beginQuickDisconnectDetection()
    }

    /// 結束一次 `beginQuickDisconnectDetection()`。
    public func endQuickDisconnectDetection() async {
        await connection.endQuickDisconnectDetection()
    }

    /// 讀主機目前的全量狀態(`session.snapshot`)。
    public func snapshot() async throws -> HostSnapshot {
        let result = try await request(method: "session.snapshot", as: SnapshotResult.self)
        return result.snapshot.hostSnapshot
    }

    /// 健康檢查：伺服器版本(行為規格 §3.4 `ping`)。
    public func ping() async throws -> String {
        try await request(method: "ping", as: PingResult.self).version
    }

    /// 主機上 herdr 的 agent 整合(`integration.list`)。
    public func integrations() async throws -> [AgentIntegration] {
        try await request(method: "integration.list", as: IntegrationListResult.self).integrations.map {
            AgentIntegration(
                target: $0.target, label: $0.label ?? $0.target,
                state: AgentIntegration.State(rawValue: $0.state ?? "") ?? .unknown, available: $0.available ?? false)
        }
    }

    /// 在場回報(`pane.report_metadata`,行為規格 F5.13):讓桌機 herdr 側欄顯示「手機正在看這個 Agent、用什麼模型」。
    ///
    /// `seq` 必須單調遞增且以時鐘起算:herdr 忽略不大於上次的 seq(即使過了 TTL),從 0 起算會在每次重開後隱形(R-H22)。
    /// 模型未知時省略該 token(空 token 在側欄是空欄)。純裝飾，呼叫端可忽略失敗。
    public func reportPresence(paneID: String, model: String?, seq: UInt64) async throws {
        var tokens = ["phone": "on"]
        if let model, !model.isEmpty { tokens["model"] = String(model.prefix(80)) }
        let params = ReportMetadataParams(paneID: paneID, source: "purrdr:presence", tokens: tokens, ttlMs: 45_000, seq: seq)
        _ = try await request(method: "pane.report_metadata", params: params, as: TypedResult.self)
    }

    /// 讀 pane 目前看得到的畫面(`pane.read`,source `visible`,行為規格 §4.8)。Claude 在 alternate screen,
    /// `recent` 會是空的，所以一定用 `visible`。
    ///
    /// `format` 預設 `.text`(不帶 `format`,herdr 去掉 ANSI);`.ansi` 保留 SGR 等跳脫序列，行尾是 `\r\n`
    /// (#122:建議提示詞只能從 dim 屬性認出來)。
    public func readPane(paneID: String, lines: Int = 40, format: PaneReadFormat = .text) async throws -> String {
        let params = PaneReadParams(paneID: paneID, source: "visible", lines: lines, format: format == .ansi ? "ansi" : nil)
        let result = try await request(method: "pane.read", params: params, as: PaneReadResult.self)
        return result.read.text
    }

    /// 訂閱事件(`events.subscribe`)。
    ///
    /// 持續讀事件，直到主機那端結束、herdr 回錯誤(例如 `events_lost`),或呼叫端不再讀(此時關閉串流)。
    /// 串流第一項是 `.subscriptionStarted`;在它之前就結束算失敗(行為規格 §3.7)。
    public func subscribe(_ subscriptions: [EventSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, any Error> {
        let lines = try await connection.herdrEvents(Self.requestLine(method: "events.subscribe", params: SubscribeParams(subscriptions: subscriptions)))
        let (events, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
        let reader = Task {
            do {
                var started = false
                for try await line in lines {
                    guard let event = try Self.decodeStreamLine(line, started: started) else { continue }
                    if event == .subscriptionStarted { started = true }
                    continuation.yield(event)
                }
                guard started else { throw HerdrError.noResponse(exitCode: nil, stderr: "") }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in reader.cancel() }
        return events
    }

    /// 串流中的一行:ack、事件，或錯誤 envelope(丟出)。ack 之後看不懂的行略過。
    private static func decodeStreamLine(_ line: Data, started: Bool) throws -> HerdrEvent? {
        guard let decoded = try? JSONDecoder().decode(StreamLine.self, from: line) else {
            if started { return nil }
            throw HerdrError.malformedResponse
        }
        if let error = decoded.error { throw HerdrError.herdr(code: error.code, message: error.message) }
        if decoded.result?.type == "subscription_started" { return .subscriptionStarted }
        if let name = decoded.event { return .event(name: name, paneID: decoded.data?.paneID) }
        return nil
    }

    // MARK: - Workspace 操作(行為規格 F3.4、F3.5)

    /// 重新命名 workspace(`workspace.rename`)。herdr 可能正規化 label,成功後應重讀 snapshot。
    public func renameWorkspace(_ workspaceID: String, to label: String) async throws {
        _ = try await request(method: "workspace.rename", params: RenameParams(workspaceID: workspaceID, label: label), as: TypedResult.self)
    }

    /// 關閉 workspace(`workspace.close`):裡面每個 tab、pane、程序都會停止。
    ///
    /// 不帶 `close_group`:同 repo 的 worktree workspace 還開著時，herdr 回 `workspace_group_close_required`,
    /// 由使用者先關掉它們，而不是替他一起關(herdr CLI 文件「Worktrees」)。
    public func closeWorkspace(_ workspaceID: String) async throws {
        _ = try await request(method: "workspace.close", params: WorkspaceIDParams(workspaceID: workspaceID), as: TypedResult.self)
    }

    /// 以 workspace 所在的 git repo 為底建立 worktree 與新分支，並開成新的 workspace(`worktree.create`)。
    /// `focus:false`:不搶桌機的焦點。分支已存在時 herdr 直接 checkout,否則從 `HEAD` 建立。
    public func createWorktree(from workspaceID: String, branch: String) async throws -> CreatedWorkspace {
        let result = try await request(
            method: "worktree.create", params: WorktreeCreateParams(workspaceID: workspaceID, branch: branch), as: WorktreeCreatedResult.self
        )
        return CreatedWorkspace(workspaceID: result.workspace.workspaceID, rootPaneID: result.rootPane.paneID)
    }

    // MARK: - 新對話(行為規格 F3.2)

    /// 在 `cwd`(主機上的絕對路徑，呼叫端先確認存在)建立 workspace(`workspace.create`,期限 60 秒)。
    /// `focus:false`:不搶桌機的焦點。`label` 為 `nil` 時由 herdr 命名。
    public func createWorkspace(cwd: String, label: String?) async throws -> CreatedWorkspace {
        let result = try await request(
            method: "workspace.create", params: WorkspaceCreateParams(cwd: cwd, label: label), as: WorktreeCreatedResult.self, deadline: .seconds(60)
        )
        return CreatedWorkspace(workspaceID: result.workspace.workspaceID, rootPaneID: result.rootPane.paneID)
    }

    /// 在 pane 的 shell 啟動 agent(`agent.start`)。`arguments` 是交給 agent 的參數(CLI 的 `--` 之後)。
    /// 我方期限 = herdr 的等待 + 60 秒：絕不比 herdr 先放棄，否則重試會在同一個 pane 再啟動一個 agent。
    /// `resumeSession`(#309)是要續接的 session id;只有主機服務(HTTPS)認得，herdr 本身沒有這個參數。
    public func startAgent(
        name: String, kind: String, paneID: String, arguments: [String], resumeSession: String? = nil, timeout: Duration
    ) async throws {
        let params = AgentStartParams(
            name: name, kind: kind, paneID: paneID, args: arguments.isEmpty ? nil : arguments, resumeSession: resumeSession,
            timeoutMs: Self.milliseconds(timeout))
        _ = try await request(method: "agent.start", params: params, as: TypedResult.self, deadline: timeout + .seconds(60))
    }

    /// 資料夾 `cwd` 過去的 `agent`(`claude`／`codex`)session,新到舊(#309)。只有主機服務(HTTPS)提供;
    /// 其他主機丟 herdr 的未知 method 錯誤，呼叫端先以主機服務版本判斷。
    public func listSessions(cwd: String, agent: String) async throws -> [ResumableSession] {
        let result = try await request(method: "sessions.list", params: SessionsListParams(cwd: cwd, agentKind: agent), as: SessionsListResult.self)
        return result.sessions.map { entry in
            ResumableSession(
                id: entry.id, modified: try? Date(entry.modified, strategy: .iso8601),
                summary: entry.summary.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    // MARK: - 送出 prompt 與按鍵(行為規格 F6.5、§3.6)

    /// `agent.prompt`。`wait` 有值時帶 `wait: {until: [working, blocked], timeout_ms}`,我方期限是 herdr 的等待 + 20 秒
    /// (否則會放棄一個即將回答的等待，回報主機沒發生的失敗,§3.6);沒有 `wait`(slash 指令)期限 20 秒。
    ///
    /// herdr 的錯誤 envelope 丟 `HerdrError.herdr`;其他錯誤(通道失敗、沒有回應、期限到)都代表
    /// **不知道有沒有送到**,呼叫端絕不可重送(§7.3)。
    ///
    /// `expecting` 交給主機在送出前比對(`SendExpectation`);不符時丟 `HostServiceError.paneChanged`,什麼都沒送出。
    public func prompt(target: String, text: String, wait: Duration?, expecting: SendExpectation = .none) async throws -> PromptReply {
        let params = PromptParams(
            target: target, text: text,
            wait: wait.map { PromptParams.Wait(until: ["working", "blocked"], timeoutMs: Self.milliseconds($0)) },
            expected: await checked(expecting)
        )
        let result = try await request(
            method: "agent.prompt", params: params, as: PromptResult.self, deadline: (wait ?? .zero) + HostCommandDeadline.standard)
        return PromptReply(writtenOnly: result.delivery == "written_to_pty")
    }

    /// `agent.wait`:等 agent 進入 `until` 其中一個狀態。herdr 自己逾時回 `false`(`timeout` 錯誤);期限是等待 + 20 秒。
    public func waitForAgent(target: String, until: [AgentStatus], timeout: Duration) async throws -> Bool {
        let params = WaitParams(target: target, until: until.map(\.rawValue), timeoutMs: Self.milliseconds(timeout))
        do {
            _ = try await request(method: "agent.wait", params: params, as: TypedResult.self, deadline: timeout + HostCommandDeadline.standard)
            return true
        } catch HerdrError.herdr(code: "timeout", _) {
            return false
        }
    }

    /// `pane.send_keys`(herdr 鍵名語法：`enter`、`esc`、`ctrl+c`,§3.4)。
    public func sendKeys(paneID: String, keys: [String], expecting: SendExpectation = .none) async throws {
        _ = try await request(method: "pane.send_keys", params: SendKeysParams(paneID: paneID, keys: keys, expected: await checked(expecting)), as: TypedResult.self)
    }

    /// `pane.send_text`:把文字原樣打進 pane(不含 Enter)。用在 Claude 問題卡「Type something.」的自訂回答(#120)。
    public func sendText(paneID: String, text: String, expecting: SendExpectation = .none) async throws {
        _ = try await request(method: "pane.send_text", params: SendTextParams(paneID: paneID, text: text, expected: await checked(expecting)), as: TypedResult.self)
    }

    /// 主機會比對時才帶比對欄位;herdr(SSH 主機)與舊版主機服務不認得它們。
    private func checked(_ expectation: SendExpectation) async -> SendExpectation {
        guard !expectation.isEmpty, await connection.checksSendExpectations() else { return .none }
        return expectation
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - 請求

    private func request<Result: Decodable>(
        method: String, params: some Encodable = NoParams(), as: Result.Type, deadline: Duration = HostCommandDeadline.standard
    ) async throws -> Result {
        let line = try await connection.herdrRequest(Self.requestLine(method: method, params: params), deadline: deadline)
        return try Self.decode(line, as: Result.self)
    }

    /// 一行請求(結尾換行)。請求 id 固定是 `purrdr:<method>`:一個 bridge 程序只處理一個請求。
    private static func requestLine(method: String, params: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(WireRequest(id: "purrdr:\(method)", method: method, params: params)) + [0x0A]
    }

    private static func decode<Result: Decodable>(_ line: Data, as: Result.Type) throws -> Result {
        let envelope: Envelope<Result>
        do {
            envelope = try JSONDecoder().decode(Envelope<Result>.self, from: line)
        } catch {
            throw HerdrError.malformedResponse
        }
        if let error = envelope.error { throw HerdrError.herdr(code: error.code, message: error.message) }
        guard let result = envelope.result else { throw HerdrError.malformedResponse }
        return result
    }
}

/// 呼叫 herdr 的錯誤。
public enum HerdrError: Error, Equatable {
    /// herdr 回了錯誤 envelope。未知的碼保留 herdr 原文(行為規格 §3.8)。
    case herdr(code: String, message: String)
    /// 指令結束時 stdout 沒有任何回應。
    case noResponse(exitCode: Int32?, stderr: String)
    /// 回應不是 herdr 的 JSON envelope。
    case malformedResponse
    /// 我方期限到了還沒有回應(連線層逾時;主機可能已經執行，§7.3)。
    case deadlineExceeded
}

/// `agent.prompt` 的成功回應。
public struct PromptReply: Sendable, Equatable {
    /// 主機只知道 bytes 寫進了終端機(fork 版的 `delivery: "written_to_pty"`;上游 herdr 不會送，§3.6)。
    public var writtenOnly: Bool

    public init(writtenOnly: Bool) {
        self.writtenOnly = writtenOnly
    }
}

// MARK: - wire format(只在這裡處理 snake_case)

private struct WireRequest<Params: Encodable>: Encodable {
    var id: String
    var method: String
    var params: Params
}

private struct NoParams: Encodable {}

private struct PromptParams: Encodable {
    var target: String
    var text: String
    var wait: Wait?
    /// 送出前比對(#304);`nil` 不編碼。
    var expectedSession: String?

    init(target: String, text: String, wait: Wait?, expected: SendExpectation) {
        self.target = target
        self.text = text
        self.wait = wait
        expectedSession = expected.session
    }

    enum CodingKeys: String, CodingKey {
        case target, text, wait
        case expectedSession = "expected_session"
    }

    struct Wait: Encodable {
        var until: [String]
        var timeoutMs: Int

        enum CodingKeys: String, CodingKey {
            case until
            case timeoutMs = "timeout_ms"
        }
    }
}

private struct PromptResult: Decodable {
    var type: String?
    var delivery: String?
}

private struct WaitParams: Encodable {
    var target: String
    var until: [String]
    var timeoutMs: Int

    enum CodingKeys: String, CodingKey {
        case target
        case until
        case timeoutMs = "timeout_ms"
    }
}

private struct SendKeysParams: Encodable {
    var paneID: String
    var keys: [String]
    var expectedSession: String?

    init(paneID: String, keys: [String], expected: SendExpectation) {
        self.paneID = paneID
        self.keys = keys
        expectedSession = expected.session
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case keys
        case expectedSession = "expected_session"
    }
}

private struct SendTextParams: Encodable {
    var paneID: String
    var text: String
    var expectedSession: String?

    init(paneID: String, text: String, expected: SendExpectation) {
        self.paneID = paneID
        self.text = text
        expectedSession = expected.session
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case text
        case expectedSession = "expected_session"
    }
}

private struct WorkspaceIDParams: Encodable {
    var workspaceID: String

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }
}

private struct RenameParams: Encodable {
    var workspaceID: String
    var label: String

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label
    }
}

private struct WorktreeCreateParams: Encodable {
    var workspaceID: String
    var branch: String
    var focus = false

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case branch
        case focus
    }
}

private struct WorkspaceCreateParams: Encodable {
    var cwd: String
    var label: String?
    var focus = false
}

private struct AgentStartParams: Encodable {
    var name: String
    var kind: String
    var paneID: String
    var args: [String]?
    var resumeSession: String?
    var timeoutMs: Int

    enum CodingKeys: String, CodingKey {
        case name, kind, args
        case paneID = "pane_id"
        case resumeSession = "resume_session"
        case timeoutMs = "timeout_ms"
    }
}

private struct SessionsListParams: Encodable {
    var cwd: String
    var agentKind: String

    enum CodingKeys: String, CodingKey {
        case cwd
        case agentKind = "agent_kind"
    }
}

private struct SessionsListResult: Decodable {
    struct Entry: Decodable {
        var id: String
        var modified: String
        var summary: String?
    }

    var sessions: [Entry]
}

/// `workspace_created` 與 `worktree_created` 共用:都有 workspace 與 root_pane。
private struct WorktreeCreatedResult: Decodable {
    var workspace: WireWorkspace
    var rootPane: RootPane

    struct RootPane: Decodable {
        var paneID: String

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case workspace
        case rootPane = "root_pane"
    }
}

private struct ReportMetadataParams: Encodable {
    var paneID: String
    var source: String
    var tokens: [String: String]
    var ttlMs: Int
    var seq: UInt64

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case source
        case tokens
        case ttlMs = "ttl_ms"
        case seq
    }
}

private struct PaneReadParams: Encodable {
    var paneID: String
    var source: String
    var lines: Int
    /// `nil` 時不送(herdr 預設 `text`),既有請求的 bytes 不變。
    var format: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case source
        case lines
        case format
    }
}

private struct PaneReadResult: Decodable {
    struct Read: Decodable {
        var text: String
    }

    var read: Read
}

/// 只有 `{"type":…}` 的結果(例如 `{"type":"ok"}`)。
private struct TypedResult: Decodable {
    var type: String?
}

private struct SubscribeParams: Encodable {
    var subscriptions: [EventSubscription]
}

extension EventSubscription: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type.rawValue, forKey: .type)
        try container.encodeIfPresent(paneID, forKey: .paneID)
    }
}

/// 訂閱串流的一行:`{id,result:{type:"subscription_started"}}`、`{event,data}` 或 `{id,error}`。
private struct StreamLine: Decodable {
    var result: Started?
    var error: WireError?
    var event: String?
    var data: EventData?

    struct Started: Decodable {
        var type: String?
    }

    /// 有些事件的 pane id 在頂層，有些包在 `pane` 物件內。
    struct EventData: Decodable {
        var paneID: String?

        private enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case pane
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let nested = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .pane)
            paneID = (try? container.decodeIfPresent(String.self, forKey: .paneID))
                ?? (try? nested?.decodeIfPresent(String.self, forKey: .paneID))
        }
    }
}

private struct Envelope<Result: Decodable>: Decodable {
    var result: Result?
    var error: WireError?
}

private struct WireError: Decodable {
    var code: String
    var message: String
}

private struct PingResult: Decodable {
    var version: String
}

private struct IntegrationListResult: Decodable {
    var integrations: [WireIntegration]
}

private struct WireIntegration: Decodable {
    var target: String
    var label: String?
    var available: Bool?
    var state: String?
}

private struct SnapshotResult: Decodable {
    var snapshot: WireSnapshot
}

private struct WireSnapshot: Decodable {
    var version: String
    var workspaces: [WireWorkspace]?
    var agents: [WireAgent]?
    var tabs: [WireTab]?
    var panes: [WirePane]?
    var layouts: [WireLayout]?

    var hostSnapshot: HostSnapshot {
        let labels = Dictionary((workspaces ?? []).map { ($0.workspaceID, $0.label) }, uniquingKeysWith: { first, _ in first })
        return HostSnapshot(
            version: version,
            workspaces: (workspaces ?? []).map {
                Workspace(id: $0.workspaceID, number: $0.number ?? 0, label: $0.label.nonEmpty, activeTabID: $0.activeTabID.nonEmpty)
            },
            agents: (agents ?? []).map { $0.agent(workspaceLabel: labels[$0.workspaceID] ?? nil) },
            tabs: (tabs ?? []).map { Tab(id: $0.tabID, workspaceID: $0.workspaceID, number: $0.number ?? 0, label: $0.label.nonEmpty) },
            panes: (panes ?? []).map(\.pane),
            layouts: layouts?.map(\.tabLayout)
        )
    }
}

private struct WireTab: Decodable {
    var tabID: String
    var workspaceID: String
    var number: Int?
    var label: String?

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case number
        case label
    }
}

private struct WirePane: Decodable {
    var paneID: String
    var workspaceID: String
    var tabID: String
    var agent: String?
    var cwd: String?
    var label: String?
    var terminalTitleStripped: String?
    var restoreError: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agent
        case cwd
        case label
        case terminalTitleStripped = "terminal_title_stripped"
        case restoreError = "restore_error"
    }

    var pane: Pane {
        Pane(
            id: paneID, workspaceID: workspaceID, tabID: tabID, agentKind: agent.nonEmpty, cwd: cwd.nonEmpty,
            label: label.nonEmpty, terminalTitle: terminalTitleStripped.nonEmpty, restoreError: restoreError.nonEmpty
        )
    }
}

private struct WireLayout: Decodable {
    var workspaceID: String
    var tabID: String
    var zoomed: Bool?
    var focusedPaneID: String?
    var panes: [WirePaneRect]?

    struct WirePaneRect: Decodable {
        var paneID: String
        var rect: WireRect

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case rect
        }
    }

    struct WireRect: Decodable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case zoomed
        case focusedPaneID = "focused_pane_id"
        case panes
    }

    var tabLayout: TabLayout {
        TabLayout(
            workspaceID: workspaceID, tabID: tabID, zoomed: zoomed ?? false, focusedPaneID: focusedPaneID.nonEmpty,
            panes: (panes ?? []).map {
                TabLayout.PaneRect(paneID: $0.paneID, rect: GridRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height))
            }
        )
    }
}

private struct WireWorkspace: Decodable {
    var workspaceID: String
    var number: Int?
    var label: String?
    var activeTabID: String?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number
        case label
        case activeTabID = "active_tab_id"
    }
}

private struct WireAgent: Decodable {
    var paneID: String
    var workspaceID: String
    var agent: String?
    var agentStatus: String?
    var name: String?
    var terminalTitleStripped: String?
    var title: String?
    var inputPending: Bool?
    var cwd: String?
    var tabID: String?
    var agentSession: WireSession?

    struct WireSession: Decodable {
        var kind: String?
        var value: String?
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agent
        case agentStatus = "agent_status"
        case name
        case terminalTitleStripped = "terminal_title_stripped"
        case title
        case inputPending = "input_pending"
        case cwd
        case tabID = "tab_id"
        case agentSession = "agent_session"
    }

    func agent(workspaceLabel: String?) -> Agent {
        Agent(
            paneID: paneID,
            workspaceID: workspaceID,
            kind: agent ?? "",
            status: agentStatus.flatMap(AgentStatus.init(rawValue:)) ?? .unknown,
            name: name.nonEmpty,
            terminalTitle: terminalTitleStripped.nonEmpty,
            sessionTitle: title.nonEmpty,
            inputPending: inputPending ?? false,
            workspaceLabel: workspaceLabel.nonEmpty,
            cwd: cwd.nonEmpty,
            session: agentSession.flatMap { wire in
                guard let kind = wire.kind, let value = wire.value else { return nil }
                return AgentSessionReference(kind: kind, value: value)
            },
            tabID: tabID.nonEmpty
        )
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
