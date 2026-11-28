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
    public func isReadOnlyDevice() async throws -> Bool {
        try await connection.isReadOnlyDevice()
    }

    /// 主機服務的版本;沒有主機服務的連線方式(SSH)是 `nil`,連不上時丟錯誤。
    public func hostServiceVersion() async throws -> String? {
        try await connection.hostServiceVersion()
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
        try await connection.readSnapshot()
    }

    /// 健康檢查：伺服器版本(行為規格 §3.4 `ping`)。
    public func ping() async throws -> String {
        try await connection.herdrVersion()
    }

    /// 主機上 herdr 的 agent 整合(`integration.list`)。
    public func integrations() async throws -> [AgentIntegration] {
        try await connection.listIntegrations()
    }

    /// 在場回報(`pane.report_metadata`,行為規格 F5.13):讓桌機 herdr 側欄顯示「手機正在看這個 Agent、用什麼模型」。
    ///
    /// `seq` 必須單調遞增且以時鐘起算:herdr 忽略不大於上次的 seq(即使過了 TTL),從 0 起算會在每次重開後隱形(R-H22)。
    /// 模型未知時省略該 token(空 token 在側欄是空欄)。純裝飾，呼叫端可忽略失敗。
    public func reportPresence(paneID: String, model: String?, seq: UInt64) async throws {
        try await connection.reportPresence(paneID: paneID, model: model, seq: seq)
    }

    /// 讀 pane 目前看得到的畫面(`pane.read`,source `visible`,行為規格 §4.8)。Claude 在 alternate screen,
    /// `recent` 會是空的，所以一定用 `visible`。
    ///
    /// `format` 預設 `.text`(不帶 `format`,herdr 去掉 ANSI);`.ansi` 保留 SGR 等跳脫序列，行尾是 `\r\n`
    /// (#122:建議提示詞只能從 dim 屬性認出來)。
    public func readPane(paneID: String, lines: Int = 40, format: PaneReadFormat = .text) async throws -> String {
        try await connection.readPaneScreen(paneID: paneID, lines: lines, format: format)
    }

    /// 訂閱事件(`events.subscribe`)。
    ///
    /// 持續讀事件，直到主機那端結束、herdr 回錯誤(例如 `events_lost`),或呼叫端不再讀(此時關閉串流)。
    /// 串流第一項是 `.subscriptionStarted`;在它之前就結束算失敗(行為規格 §3.7)。
    public func subscribe(_ subscriptions: [EventSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, any Error> {
        try await connection.subscribeToEvents(subscriptions)
    }

    // MARK: - Workspace 操作(行為規格 F3.4、F3.5)

    /// 重新命名 workspace(`workspace.rename`)。herdr 可能正規化 label,成功後應重讀 snapshot。
    public func renameWorkspace(_ workspaceID: String, to label: String) async throws {
        try await connection.renameWorkspace(workspaceID, to: label)
    }

    /// 重新命名 tab(`tab.rename`,herdr 0.9.5;#456)。herdr 可能正規化 label,成功後應重讀 snapshot。
    public func renameTab(_ tabID: String, to label: String) async throws {
        try await connection.renameTab(tabID, to: label)
    }

    /// 關閉 tab(`tab.close`):裡面的 pane、程序都會停止。herdr 0.9.5 實測:關掉 workspace 最後一個 tab 時,
    /// workspace 也一併關閉(不是錯誤);連最後一個 workspace 也關掉時 herdr 會自己開一個新的空 workspace。
    public func closeTab(_ tabID: String) async throws {
        try await connection.closeTab(tabID)
    }

    /// 關閉 workspace(`workspace.close`):裡面每個 tab、pane、程序都會停止。
    ///
    /// 不帶 `close_group`:同 repo 的 worktree workspace 還開著時，herdr 回 `workspace_group_close_required`,
    /// 由使用者先關掉它們，而不是替他一起關(herdr CLI 文件「Worktrees」)。
    public func closeWorkspace(_ workspaceID: String) async throws {
        try await connection.closeWorkspace(workspaceID)
    }

    /// 以 workspace 所在的 git repo 為底建立 worktree 與新分支，並開成新的 workspace(`worktree.create`)。
    /// `focus:false`:不搶桌機的焦點。分支已存在時 herdr 直接 checkout,否則從 `HEAD` 建立。
    public func createWorktree(from workspaceID: String, branch: String) async throws -> CreatedWorkspace {
        try await connection.createWorktree(from: workspaceID, branch: branch)
    }

    // MARK: - 新對話(行為規格 F3.2)

    /// 在 `cwd`(主機上的絕對路徑，呼叫端先確認存在)建立 workspace(`workspace.create`,期限 60 秒)。
    /// `focus:false`:不搶桌機的焦點。`label` 為 `nil` 時由 herdr 命名。
    /// `tabLabel`(#532)有值時,建好後對新 tab 送 `tab.rename`;命名只是順手的事,失敗不讓新對話失敗。
    public func createWorkspace(cwd: String, label: String?, tabLabel: String? = nil) async throws -> CreatedWorkspace {
        let created = try await connection.createWorkspace(cwd: cwd, label: label)
        if let tabLabel, let tabID = created.rootTabID {
            try? await renameTab(tabID, to: tabLabel)
        }
        return created.workspace
    }

    /// 建立 workspace 與 tab 的我方期限(herdr 要建 PTY 與 shell)。
    package static let createDeadline = Duration.seconds(60)

    /// 在既有 workspace 新增 tab(`tab.create`,#537;herdr 0.9.5 實測:不帶 `cwd` 沿用 workspace 的工作目錄,
    /// workspace 不存在回 `workspace_not_found`)。`focus:false`:不搶桌機的焦點。`label` 為 `nil` 時由 herdr 命名。
    public func createTab(in workspaceID: String, label: String?) async throws -> CreatedTab {
        try await connection.createTab(in: workspaceID, label: label)
    }

    /// 在 pane 的 shell 啟動 agent(`agent.start`)。`arguments` 是交給 agent 的參數(CLI 的 `--` 之後)。
    /// 我方期限 = herdr 的等待 + 60 秒：絕不比 herdr 先放棄，否則重試會在同一個 pane 再啟動一個 agent。
    /// `resumeSession`(#309)是要續接的 session id;herdr 本身沒有這個參數:HTTPS 主機服務直接收，SSH 連線層換成 `args` 的 `--resume <id>`／`resume <id>`(#535)。
    ///
    /// 回傳 agent 是否已就緒(可以收 prompt)。herdr 0.9.5 在資料夾還沒被信任等情況下會立刻回成功、
    /// 但 agent 帶 `launch_pending: true`;這時送 `agent.prompt` 會得到 `agent_not_ready`
    /// 「agent w2:p1 is not an active named agent」,所以呼叫端要先以 `agentLaunchState(target:)` 輪詢到就緒才送第一則訊息。
    /// HTTPS 主機服務(0.15.0 起,purrdr.host#92)在主機端輪詢到就緒、停在 blocked 或逾時才回,`launch_pending` 是最終結果
    /// (true 就是未就緒,呼叫端不送第一則訊息、不再輪詢);更舊的主機服務沒有這個欄位,一律當就緒,
    /// `agent.prompt` 回 `agent_not_ready` 時呼叫端不送、訊息留給輸入框。
    @discardableResult
    public func startAgent(
        name: String, kind: String, paneID: String, arguments: [String], resumeSession: String? = nil, timeout: Duration
    ) async throws -> Bool {
        try await connection.startAgent(AgentStartRequest(
            name: name, kind: kind, paneID: paneID, arguments: arguments, resumeSession: resumeSession, timeout: timeout))
    }

    /// 我方期限 = herdr 的等待 + 60 秒。
    package static func startDeadline(timeout: Duration) -> Duration { timeout + .seconds(60) }

    /// `agent.get`(`target` 是 root pane id):讀剛啟動的 agent 的就緒狀態(herdr 0.9.5 的 `result.agent`)。
    /// `agent.start` 回 `launch_pending` 後以它輪詢;沒有這個 agent 丟 `agent_not_found` 等 herdr 錯誤。
    public func agentLaunchState(target: String) async throws -> AgentLaunchState {
        try await connection.agentLaunchState(target: target)
    }

    /// 資料夾 `cwd` 過去的 `agent`(`claude`／`codex`)session,新到舊(#309)。主機服務(HTTPS)的 `sessions.list`;
    /// SSH 由連線層以腳本列出(#535);版本太舊的主機服務丟未知 method 錯誤，呼叫端先以主機服務版本判斷。
    public func listSessions(cwd: String, agent: String) async throws -> [ResumableSession] {
        try await connection.listSessions(cwd: cwd, agent: agent)
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
        try await connection.sendPrompt(target: target, text: text, wait: wait, expecting: expecting)
    }

    /// 我方期限 = herdr 的等待 + 20 秒(沒有等待是 20 秒)。
    package static func promptDeadline(wait: Duration?) -> Duration { (wait ?? .zero) + HostCommandDeadline.standard }

    /// `agent.wait`:等 agent 進入 `until` 其中一個狀態。herdr 自己逾時回 `false`(`timeout` 錯誤);期限是等待 + 20 秒。
    public func waitForAgent(target: String, until: [AgentStatus], timeout: Duration) async throws -> Bool {
        try await connection.waitForAgent(target: target, until: until, timeout: timeout)
    }

    /// `pane.send_keys`(herdr 鍵名語法：`enter`、`esc`、`ctrl+c`,§3.4)。
    public func sendKeys(paneID: String, keys: [String], expecting: SendExpectation = .none) async throws {
        try await connection.sendKeys(paneID: paneID, keys: keys, expecting: expecting)
    }

    /// `pane.send_text`:把文字原樣打進 pane(不含 Enter)。用在 Claude 問題卡「Type something.」的自訂回答(#120)。
    public func sendText(paneID: String, text: String, expecting: SendExpectation = .none) async throws {
        try await connection.sendText(paneID: paneID, text: text, expecting: expecting)
    }

    // MARK: - 請求

}

/// herdr NDJSON 的 wire 實作(SSH 連線方式用,ADR-0015):請求一行 NDJSON 進、回應一行出,事件逐行。
/// HTTPS 直接對應主機服務訊息,不經這裡;wire format(snake_case)只在這個檔案處理。
package struct HerdrWireClient: Sendable {
    private let wire: any HerdrWire

    package init(wire: any HerdrWire) {
        self.wire = wire
    }

    /// `snapshot()` 的 herdr NDJSON 實作(SSH 的型別化操作用)。
    package func snapshot() async throws -> HostSnapshot {
        let result = try await request(method: "session.snapshot", as: SnapshotResult.self)
        return result.snapshot.hostSnapshot
    }

    package func ping() async throws -> String {
        try await request(method: "ping", as: PingResult.self).version
    }

    package func integrations() async throws -> [AgentIntegration] {
        try await request(method: "integration.list", as: IntegrationListResult.self).integrations.map {
            AgentIntegration(
                target: $0.target, label: $0.label ?? $0.target,
                state: AgentIntegration.State(rawValue: $0.state ?? "") ?? .unknown, available: $0.available ?? false)
        }
    }

    package func reportPresence(paneID: String, model: String?, seq: UInt64) async throws {
        var tokens = ["phone": "on"]
        if let model, !model.isEmpty { tokens["model"] = String(model.prefix(80)) }
        let params = ReportMetadataParams(paneID: paneID, source: "purrdr:presence", tokens: tokens, ttlMs: 45_000, seq: seq)
        _ = try await request(method: "pane.report_metadata", params: params, as: TypedResult.self)
    }

    /// `readPane` 的 herdr NDJSON 實作。
    package func readPane(paneID: String, lines: Int, format: PaneReadFormat) async throws -> String {
        let params = PaneReadParams(paneID: paneID, source: "visible", lines: lines, format: format == .ansi ? "ansi" : nil)
        let result = try await request(method: "pane.read", params: params, as: PaneReadResult.self)
        return result.read.text
    }

    /// `subscribe` 的 herdr NDJSON 實作。
    package func subscribe(_ subscriptions: [EventSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, any Error> {
        let lines = try await wire.herdrEvents(Self.requestLine(method: "events.subscribe", params: SubscribeParams(subscriptions: subscriptions)))
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

    /// 一行事件串流的內容(已過 ack):事件、`nil`(看不懂的行略過),或錯誤 envelope(丟出)。測試的假連線用它把事件行換成型別化事件。
    package static func decodeEventLine(_ line: Data) throws -> HerdrEvent? {
        try decodeStreamLine(line, started: true)
    }

    /// 事件串流從第一行起逐行判讀(ack 之前看不懂的行算失敗);測試的假連線把錄製的回應換成型別化事件用。
    package static func decodeEventStream(_ line: Data, started: Bool) throws -> HerdrEvent? {
        try decodeStreamLine(line, started: started)
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

    package func renameWorkspace(_ workspaceID: String, to label: String) async throws {
        _ = try await request(method: "workspace.rename", params: RenameParams(workspaceID: workspaceID, label: label), as: TypedResult.self)
    }

    package func renameTab(_ tabID: String, to label: String) async throws {
        _ = try await request(method: "tab.rename", params: TabRenameParams(tabID: tabID, label: label), as: TypedResult.self)
    }

    package func closeTab(_ tabID: String) async throws {
        _ = try await request(method: "tab.close", params: TabIDParams(tabID: tabID), as: TypedResult.self)
    }

    package func closeWorkspace(_ workspaceID: String) async throws {
        _ = try await request(method: "workspace.close", params: WorkspaceIDParams(workspaceID: workspaceID), as: TypedResult.self)
    }

    package func createWorktree(from workspaceID: String, branch: String) async throws -> CreatedWorkspace {
        let result = try await request(
            method: "worktree.create", params: WorktreeCreateParams(workspaceID: workspaceID, branch: branch), as: WorktreeCreatedResult.self
        )
        return CreatedWorkspace(workspaceID: result.workspace.workspaceID, rootPaneID: result.rootPane.paneID)
    }

    package func createWorkspace(cwd: String, label: String?) async throws -> NewWorkspace {
        let result = try await request(
            method: "workspace.create", params: WorkspaceCreateParams(cwd: cwd, label: label), as: WorktreeCreatedResult.self,
            deadline: HerdrClient.createDeadline)
        return NewWorkspace(
            workspace: CreatedWorkspace(workspaceID: result.workspace.workspaceID, rootPaneID: result.rootPane.paneID),
            rootTabID: result.rootPane.tabID)
    }

    package func createTab(in workspaceID: String, label: String?) async throws -> CreatedTab {
        let result = try await request(
            method: "tab.create", params: TabCreateParams(workspaceID: workspaceID, label: label), as: TabCreatedResult.self,
            deadline: HerdrClient.createDeadline)
        return CreatedTab(workspaceID: workspaceID, tabID: result.tab.tabID, rootPaneID: result.rootPane.paneID)
    }

    package func startAgent(_ start: AgentStartRequest) async throws -> Bool {
        let params = AgentStartParams(
            name: start.name, kind: start.kind, paneID: start.paneID, args: start.arguments.isEmpty ? nil : start.arguments,
            resumeSession: start.resumeSession, timeoutMs: Self.milliseconds(start.timeout))
        let result = try await request(method: "agent.start", params: params, as: AgentStartResult.self, deadline: HerdrClient.startDeadline(timeout: start.timeout))
        return result.agent?.launchPending != true
    }

    package func agentLaunchState(target: String) async throws -> AgentLaunchState {
        let result = try await request(method: "agent.get", params: AgentGetParams(target: target), as: AgentGetResult.self)
        return AgentLaunchState(
            status: result.agent?.agentStatus.flatMap(AgentStatus.init(rawValue:)), launchPending: result.agent?.launchPending == true,
            interactiveReady: result.agent?.interactiveReady)
    }

    package func listSessions(cwd: String, agent: String) async throws -> [ResumableSession] {
        let result = try await request(method: "sessions.list", params: SessionsListParams(cwd: cwd, agentKind: agent), as: SessionsListResult.self)
        return result.sessions.map { entry in
            ResumableSession(
                id: entry.id, modified: try? Date(entry.modified, strategy: .iso8601),
                summary: entry.summary.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    package func prompt(target: String, text: String, wait: Duration?, expecting: SendExpectation) async throws -> PromptReply {
        let params = Expecting(
            PromptParams(
                target: target, text: text,
                wait: wait.map { PromptParams.Wait(until: ["working", "blocked"], timeoutMs: Self.milliseconds($0)) }),
            await checked(expecting))
        let result = try await request(
            method: "agent.prompt", params: params, as: PromptResult.self, deadline: HerdrClient.promptDeadline(wait: wait))
        return PromptReply(writtenOnly: result.delivery == "written_to_pty")
    }

    package func waitForAgent(target: String, until: [AgentStatus], timeout: Duration) async throws -> Bool {
        let params = WaitParams(target: target, until: until.map(\.rawValue), timeoutMs: Self.milliseconds(timeout))
        do {
            _ = try await request(method: "agent.wait", params: params, as: TypedResult.self, deadline: timeout + HostCommandDeadline.standard)
            return true
        } catch HerdrError.herdr(code: "timeout", _) {
            return false
        }
    }

    /// `sendKeys` 的 herdr NDJSON 實作。
    package func sendKeys(paneID: String, keys: [String], expecting: SendExpectation) async throws {
        _ = try await request(method: "pane.send_keys", params: Expecting(SendKeysParams(paneID: paneID, keys: keys), await checked(expecting)), as: TypedResult.self)
    }

    /// `sendText` 的 herdr NDJSON 實作。
    package func sendText(paneID: String, text: String, expecting: SendExpectation) async throws {
        _ = try await request(method: "pane.send_text", params: Expecting(SendTextParams(paneID: paneID, text: text), await checked(expecting)), as: TypedResult.self)
    }

    /// 主機會比對時才帶比對欄位;herdr(SSH 主機)與舊版主機服務不認得它們。
    private func checked(_ expectation: SendExpectation) async -> SendExpectation {
        guard !expectation.isEmpty, await wire.checksSendExpectations() else { return .none }
        return expectation
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private func request<Result: Decodable>(
        method: String, params: some Encodable = NoParams(), as: Result.Type, deadline: Duration = HostCommandDeadline.standard
    ) async throws -> Result {
        let line = try await wire.herdrRequest(Self.requestLine(method: method, params: params), deadline: deadline)
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
    /// 主機服務 0.17.0 起的送出確認(HTTPS):`true` 是 Agent 已開始工作、停下來問問題或狀態序號已變動;
    /// `false` 是主機補送 Enter 後仍沒有反應。`nil` 是主機這次沒做確認(舊版主機服務、沒帶 wait、Codex、SSH),照舊規則處理。
    public var submitConfirmed: Bool?
    /// 主機服務補送了 Enter(只在有補時為 `true`,否則 `nil`)。
    public var enterSent: Bool?

    public init(writtenOnly: Bool, submitConfirmed: Bool? = nil, enterSent: Bool? = nil) {
        self.writtenOnly = writtenOnly
        self.submitConfirmed = submitConfirmed
        self.enterSent = enterSent
    }
}

// MARK: - wire format(只在這裡處理 snake_case)

private struct WireRequest<Params: Encodable>: Encodable {
    var id: String
    var method: String
    var params: Params
}

private struct NoParams: Encodable {}

/// 送出類請求的參數加上送出前比對(#304):`SendExpectation` 直接編碼成 `expected_session`(沒有就不編碼),
/// 各請求的參數型別不必逐欄重複。
private struct Expecting<Base: Encodable>: Encodable {
    var base: Base
    var expectation: SendExpectation

    init(_ base: Base, _ expectation: SendExpectation) {
        self.base = base
        self.expectation = expectation
    }

    func encode(to encoder: any Encoder) throws {
        try base.encode(to: encoder)
        try expectation.encode(into: encoder)
    }
}

private struct PromptParams: Encodable {
    var target: String
    var text: String
    var wait: Wait?

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

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case keys
    }
}

private struct SendTextParams: Encodable {
    var paneID: String
    var text: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case text
    }
}

private struct WorkspaceIDParams: Encodable {
    var workspaceID: String

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }
}

private struct TabIDParams: Encodable {
    var tabID: String

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
    }
}

private struct TabCreateParams: Encodable {
    var workspaceID: String
    var label: String?
    var focus = false

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label, focus
    }
}

private struct TabCreatedResult: Decodable {
    var tab: Tab
    var rootPane: RootPane

    struct Tab: Decodable {
        var tabID: String

        enum CodingKeys: String, CodingKey { case tabID = "tab_id" }
    }

    struct RootPane: Decodable {
        var paneID: String

        enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
    }

    enum CodingKeys: String, CodingKey {
        case tab
        case rootPane = "root_pane"
    }
}

private struct TabRenameParams: Encodable {
    var tabID: String
    var label: String

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case label
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
        var tabID: String?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case tabID = "tab_id"
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

/// 剛啟動的 agent 的就緒狀態(`agent.get`)。
public struct AgentLaunchState: Sendable, Equatable {
    /// herdr 的 `agent_status`(看不懂的值是 `nil`)。
    public var status: AgentStatus?
    public var launchPending: Bool
    public var interactiveReady: Bool?

    /// 可以收 prompt:`launch_pending` 結束,或 herdr 明說可互動。
    public var isReady: Bool { interactiveReady == true || !launchPending }
    /// 停在啟動問題(例如資料夾信任):不會自己就緒。
    public var isBlocked: Bool { status == .blocked }
}

private struct AgentGetParams: Encodable {
    var target: String
}

private struct AgentGetResult: Decodable {
    var agent: Agent?

    struct Agent: Decodable {
        var agentStatus: String?
        var launchPending: Bool?
        var interactiveReady: Bool?

        enum CodingKeys: String, CodingKey {
            case agentStatus = "agent_status"
            case launchPending = "launch_pending"
            case interactiveReady = "interactive_ready"
        }
    }
}

/// `agent.start` 的成功回應;只讀 `launch_pending`(還沒就緒)。
private struct AgentStartResult: Decodable {
    var agent: Agent?

    struct Agent: Decodable {
        var launchPending: Bool?

        enum CodingKeys: String, CodingKey { case launchPending = "launch_pending" }
    }
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
