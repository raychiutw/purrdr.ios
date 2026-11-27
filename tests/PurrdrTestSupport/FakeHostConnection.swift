import Foundation
import PurrdrCore
import PurrdrSSH

/// 假的主機連線：型別化操作直接回 stub 的值或失敗，並記錄 app 送出的操作。上層功能的測試用它，就不必知道連線方式。
///
/// ```swift
/// let connection = FakeHostConnection()
/// await connection.stub(.snapshot, snapshot)                                          // 型別化的值
/// await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))  // 錄製的 herdr 回應,由 SSH 解析層判讀
/// let model = AgentListModel(client: HerdrClient(connection: connection))
/// ```
///
/// 沒有 stub 的操作一律以 `FakeHostConnectionError.unexpectedRequest` 失敗。
public actor FakeHostConnection: HostConnection {
    /// app 送出的 herdr 請求行(含 `events.subscribe`),依送出順序。
    public private(set) var requests: [String] = []
    /// 每條 Agent 事件串流是否已被 app 關閉，依開啟順序。
    public private(set) var subscriptionsClosed: [Bool] = []
    public private(set) var disconnectCount = 0


    /// `hostServiceVersion()` 回報的版本(#198);`nil` 像 SSH 一樣沒有主機服務。
    private var reportedHostServiceVersion: String?

    /// 主機服務代裝推播外掛時的假主機;`nil` 像取不到主機服務連線一樣不能代裝。
    public nonisolated let pushPlugins: FakePushPluginHost?

    public init(pushPlugins: FakePushPluginHost? = nil) {
        self.pushPlugins = pushPlugins
    }

    public func setHostServiceVersion(_ version: String?) {
        reportedHostServiceVersion = version
    }

    /// 設了就讓 `hostServiceVersion()` 丟這個錯(連不上主機);`nil` 回復正常。
    private var hostServiceVersionFailure: (any Error)?

    public func setHostServiceVersionFailure(_ failure: (any Error)?) {
        hostServiceVersionFailure = failure
    }

    public func hostServiceVersion() async throws -> String? {
        if let hostServiceVersionFailure { throw hostServiceVersionFailure }
        return reportedHostServiceVersion
    }

    /// `isReadOnlyDevice()` 的回答(#392);`true` 像以唯讀權杖配對的 HTTPS 主機。
    private var readOnlyDevice = false

    public func setReadOnlyDevice(_ readOnly: Bool) {
        readOnlyDevice = readOnly
    }

    public func isReadOnlyDevice() async throws -> Bool { readOnlyDevice }

    /// `checksSendExpectations()` 的回答(#304);`true` 像 0.7.0 起的主機服務，送出請求帶比對欄位。
    private var checksExpectations = false

    public func setChecksSendExpectations(_ checks: Bool) {
        checksExpectations = checks
    }

    public func checksSendExpectations() async -> Bool { checksExpectations }

    /// 還沒被用掉的預期(stub 與事件訂閱)。
    public var unmetExpectations: [String] {
        unmetStubs + subscriptionExpectations.map { _ in "events.subscribe" }
    }

    // MARK: - 型別化操作(ADR-0015)

    /// 型別化操作的呼叫紀錄(依序;只記操作名稱與主要參數，文字內容照原樣)。
    public private(set) var typedCalls: [String] = []

    /// 型別化 stub 的操作種類。raw value 沿用 herdr 的 method 名稱(`expect`／`hold` 也用同一組字串)。
    public enum Operation: String, Sendable {
        case snapshot = "session.snapshot"
        case sendKeys = "pane.send_keys"
        case sendText = "pane.send_text"
        case paneRead = "pane.read"
        case ping
        case integrations = "integration.list"
        case reportPresence = "pane.report_metadata"
        case workspaceRename = "workspace.rename"
        case tabRename = "tab.rename"
        case tabClose = "tab.close"
        case workspaceClose = "workspace.close"
        case worktreeCreate = "worktree.create"
        case workspaceCreate = "workspace.create"
        case tabCreate = "tab.create"
        case agentStart = "agent.start"
        case agentLaunchState = "agent.get"
        case sessionsList = "sessions.list"
        case agentPrompt = "agent.prompt"
        case agentWait = "agent.wait"
        case transcriptLocate = "transcript.locate"
        case transcriptWindow = "transcript.window"
        case transcriptTail = "transcript.tail"
        case transcriptPreviews = "transcript.previews"
        case subagentLocate = "transcript.subagent"
        case workflow = "transcript.workflow"
        case delegation = "transcript.delegation"
    }

    private var stubs: [Operation: [Result<any Sendable, any Error>]] = [:]

    /// 下一次 `operation` 直接回 `value`(同一操作依序消耗)。沒有 stub 的操作走既有的 herdr／對話紀錄回放。
    public func stub(_ operation: Operation, _ value: some Sendable) {
        stubs[operation, default: []].append(.success(value))
    }

    /// 下一次 `operation` 直接成功(沒有回傳值的操作:送鍵、送文字、重新命名、關閉、在場回報)。
    public func stub(_ operation: Operation) {
        stubs[operation, default: []].append(.success(()))
    }

    /// 下一次 `operation` 以 `failure` 失敗(例如主機服務的 `HostServiceError.paneChanged`)。
    public func stub(_ operation: Operation, failure: any Error) {
        stubs[operation, default: []].append(.failure(failure))
    }

    /// 下一次 `readSnapshot()` 直接回這個值(依序消耗)。
    public func stub(snapshot: HostSnapshot) { stub(.snapshot, snapshot) }
    /// 下一次 `readPaneScreen` 直接回這段畫面文字。
    public func stub(paneScreen: String) { stub(.paneRead, paneScreen) }
    /// 下一次 `locateTranscript` 直接回這個檔案。
    public func stub(transcriptFile: TranscriptFile) { stub(.transcriptLocate, transcriptFile) }
    /// 下一次 `readTranscriptWindow` 直接回這段。
    public func stub(transcriptChunk: TranscriptChunk) { stub(.transcriptWindow, transcriptChunk) }

    /// 還沒被用掉的 stub(操作名稱)。
    public var unmetStubs: [String] {
        stubs.flatMap { operation, results in results.map { _ in operation.rawValue } }.sorted()
    }

    /// 取出 `operation` 的下一個 stub;沒有時回 `nil`。記錄呼叫與請求行,有 `hold` 時先停住。
    private func takeStub<Value: Sendable>(
        _ operation: Operation, as type: Value.Type, call: String, params: [String: Any] = [:]
    ) async throws -> Value? {
        guard stubs[operation]?.isEmpty == false else { return nil }
        typedCalls.append(call)
        requests.append(Self.requestLine(operation.rawValue, params))
        await holdIfRequested(operation.rawValue)
        return try popStub(operation, as: type)
    }

    /// 取出 `operation` 的下一個 stub(不記錄、不停住);沒有時回 `nil`。
    private func popStub<Value: Sendable>(_ operation: Operation, as type: Value.Type) throws -> Value? {
        guard var queue = stubs[operation], !queue.isEmpty else { return nil }
        let result = queue.removeFirst()
        stubs[operation] = queue
        switch result {
        case .failure(let error): throw error
        case .success(let value):
            guard let typed = value as? Value else { throw FakeHostConnectionError.stubTypeMismatch(operation.rawValue) }
            return typed
        }
    }

    private func holdIfRequested(_ method: String) async {
        if let index = heldMethods.firstIndex(of: method) {
            heldMethods.remove(at: index)
            await withCheckedContinuation { held.append($0) }
        }
    }

    private static func requestLine(_ method: String, _ params: [String: Any]) -> String {
        let object: [String: Any] = ["method": method, "params": params]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// 主機會比對時才帶比對欄位(同真正的連線:SSH 與舊版主機服務不帶)。
    private func expectationParams(_ expecting: SendExpectation) -> [String: Any] {
        guard checksExpectations, let session = expecting.session else { return [:] }
        return ["expected_session": session]
    }

    public func readSnapshot() async throws -> HostSnapshot {
        if let snapshot = try await takeStub(.snapshot, as: HostSnapshot.self, call: "readSnapshot") { return snapshot }
        typedCalls.append("readSnapshot")
        throw FakeHostConnectionError.unexpectedRequest("readSnapshot")
    }

    public func sendKeys(paneID: String, keys: [String], expecting: SendExpectation) async throws {
        let call = "sendKeys \(paneID) \(keys.joined(separator: ","))"
        let params: [String: Any] = ["pane_id": paneID, "keys": keys].merging(expectationParams(expecting)) { $1 }
        if try await takeStub(.sendKeys, as: Void.self, call: call, params: params) != nil { return }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func sendText(paneID: String, text: String, expecting: SendExpectation) async throws {
        let call = "sendText \(paneID) \(text)"
        let params: [String: Any] = ["pane_id": paneID, "text": text].merging(expectationParams(expecting)) { $1 }
        if try await takeStub(.sendText, as: Void.self, call: call, params: params) != nil { return }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func readPaneScreen(paneID: String, lines: Int, format: PaneReadFormat) async throws -> String {
        let call = "readPaneScreen \(paneID) \(lines) \(format == .ansi ? "ansi" : "text")"
        if let screen = try await takeStub(.paneRead, as: String.self, call: call, params: ["pane_id": paneID, "lines": lines]) { return screen }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func locateTranscript(_ location: TranscriptLocation) async throws -> TranscriptFile {
        try await transcriptOperation(
            .transcriptLocate, call: "locateTranscript", served: { try $0.locate(location) })
    }

    public func readTranscriptWindow(path: String, end: Int, lines: Int, maxBytes: Int) async throws -> TranscriptChunk {
        transcriptWindowReads.append(TranscriptWindowRead(path: path, end: end, lines: lines, maxBytes: maxBytes))
        return try await transcriptOperation(
            .transcriptWindow, call: "readTranscriptWindow \(path) \(end) \(lines) \(maxBytes)",
            served: { try $0.window(path, end, lines, maxBytes) })
    }

    // herdr 的結構與 Agent 操作:有 stub 就直接回,沒有就記錄呼叫後丟 `unexpectedRequest`。

    public func herdrVersion() async throws -> String {
        if let version = try await takeStub(.ping, as: String.self, call: "herdrVersion") { return version }
        typedCalls.append("herdrVersion")
        throw FakeHostConnectionError.unexpectedRequest("herdrVersion")
    }

    public func listIntegrations() async throws -> [AgentIntegration] {
        if let list = try await takeStub(.integrations, as: [AgentIntegration].self, call: "listIntegrations") { return list }
        typedCalls.append("listIntegrations")
        throw FakeHostConnectionError.unexpectedRequest("listIntegrations")
    }

    public func reportPresence(paneID: String, model: String?, seq: UInt64) async throws {
        let call = "reportPresence \(paneID) \(model ?? "-") \(seq)"
        if try await takeStub(.reportPresence, as: Void.self, call: call, params: ["pane_id": paneID]) != nil { return }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func renameWorkspace(_ workspaceID: String, to label: String) async throws {
        let call = "renameWorkspace \(workspaceID) \(label)"
        if try await takeStub(.workspaceRename, as: Void.self, call: call, params: ["workspace_id": workspaceID, "label": label]) != nil { return }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func renameTab(_ tabID: String, to label: String) async throws {
        let call = "renameTab \(tabID) \(label)"
        if try await takeStub(.tabRename, as: Void.self, call: call, params: ["tab_id": tabID, "label": label]) != nil { return }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func closeTab(_ tabID: String) async throws {
        let call = "closeTab \(tabID)"
        if try await takeStub(.tabClose, as: Void.self, call: call, params: ["tab_id": tabID]) != nil { return }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func closeWorkspace(_ workspaceID: String) async throws {
        let call = "closeWorkspace \(workspaceID)"
        if try await takeStub(.workspaceClose, as: Void.self, call: call, params: ["workspace_id": workspaceID]) != nil { return }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func createWorktree(from workspaceID: String, branch: String) async throws -> CreatedWorkspace {
        let call = "createWorktree \(workspaceID) \(branch)"
        if let created = try await takeStub(.worktreeCreate, as: CreatedWorkspace.self, call: call, params: ["workspace_id": workspaceID, "branch": branch]) {
            return created
        }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func createWorkspace(cwd: String, label: String?) async throws -> NewWorkspace {
        let call = "createWorkspace \(cwd) \(label ?? "-")"
        if let created = try await takeStub(.workspaceCreate, as: NewWorkspace.self, call: call, params: ["cwd": cwd]) { return created }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func createTab(in workspaceID: String, label: String?) async throws -> CreatedTab {
        let call = "createTab \(workspaceID) \(label ?? "-")"
        if let created = try await takeStub(.tabCreate, as: CreatedTab.self, call: call, params: ["workspace_id": workspaceID]) { return created }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func startAgent(_ request: AgentStartRequest) async throws -> Bool {
        let call = "startAgent \(request.kind) \(request.paneID)"
        if let ready = try await takeStub(.agentStart, as: Bool.self, call: call, params: agentStartParams(request)) { return ready }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    private func agentStartParams(_ request: AgentStartRequest) -> [String: Any] {
        var params: [String: Any] = ["name": request.name, "kind": request.kind, "pane_id": request.paneID, "args": request.arguments]
        if let resume = request.resumeSession { params["resume_session"] = resume }
        return params
    }

    public func agentLaunchState(target: String) async throws -> AgentLaunchState {
        let call = "agentLaunchState \(target)"
        if let state = try await takeStub(.agentLaunchState, as: AgentLaunchState.self, call: call, params: ["target": target]) { return state }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func listSessions(cwd: String, agent: String) async throws -> [ResumableSession] {
        let call = "listSessions \(cwd) \(agent)"
        if let list = try await takeStub(.sessionsList, as: [ResumableSession].self, call: call, params: ["cwd": cwd, "agent_kind": agent]) { return list }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func sendPrompt(target: String, text: String, wait: Duration?, expecting: SendExpectation) async throws -> PromptReply {
        let call = "sendPrompt \(target) \(text)"
        let params: [String: Any] = ["target": target, "text": text].merging(expectationParams(expecting)) { $1 }
        if let reply = try await takeStub(.agentPrompt, as: PromptReply.self, call: call, params: params) { return reply }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    public func waitForAgent(target: String, until: [AgentStatus], timeout: Duration) async throws -> Bool {
        let call = "waitForAgent \(target)"
        if let reached = try await takeStub(.agentWait, as: Bool.self, call: call, params: ["target": target]) { return reached }
        typedCalls.append(call)
        throw FakeHostConnectionError.unexpectedRequest(call)
    }

    // 對話紀錄的追蹤讀取、預覽、subagent、workflow、委派:有 stub 就直接回,其次是 `serveTranscript` 設的伺服器,
    // 都沒有就丟 `unsupported`。

    public func readTranscriptTail(path: String, from cursor: Int, limit: Int, catchUp: Bool) async throws -> TranscriptTailRead {
        transcriptTailReads.append(TranscriptTailReadRequest(path: path, cursor: cursor, limit: limit, catchUp: catchUp))
        return try await transcriptOperation(
            .transcriptTail, call: "readTranscriptTail \(path) \(cursor) \(limit) \(catchUp)",
            served: { try $0.tail(path, cursor, limit, catchUp) })
    }

    public func readTranscriptPreviews(_ requests: [PreviewRequest]) async throws -> [String: TranscriptPreviewBody] {
        try await transcriptOperation(
            .transcriptPreviews, call: "readTranscriptPreviews \(requests.map(\.key).joined(separator: ","))", served: nil)
    }

    public func locateSubagent(sessionFolder: String, callID: String) async throws -> String {
        try await transcriptOperation(
            .subagentLocate, call: "locateSubagent \(callID)", served: nil)
    }

    public func readWorkflow(sessionFolder: String, runID: String, knownChecksum: String?) async throws -> WorkflowRead {
        try await transcriptOperation(
            .workflow, call: "readWorkflow \(runID)", served: nil)
    }

    public func readDelegationLines(path: String, callID: String, agentID: String, knownChecksum: String?) async throws -> DelegationRead {
        try await transcriptOperation(
            .delegation, call: "readDelegationLines \(callID)", served: nil)
    }

    /// app 送出的視窗讀取(依送出順序)。`maxBytes` 為 0 表示不限。
    public private(set) var transcriptWindowReads: [TranscriptWindowRead] = []
    /// app 送出的尾端讀取(依送出順序)。
    public private(set) var transcriptTailReads: [TranscriptTailReadRequest] = []

    /// 對話紀錄操作的共同流程:記錄呼叫、(有 `holdTranscripts` 時)停住,然後 stub → 伺服器;都沒有就 `unsupported`。
    private func transcriptOperation<Value: Sendable>(
        _ operation: Operation, call: String, served: (@Sendable (TranscriptServer) throws -> Value)?
    ) async throws -> Value {
        typedCalls.append(call)
        if holdsTranscripts { await withCheckedContinuation { heldTranscripts.append($0) } }
        if let stubbed = try popStub(operation, as: Value.self) { return stubbed }
        if let served, let transcriptServer { return try served(transcriptServer) }
        throw FakeHostConnectionError.unsupported
    }

    /// 型別化的對話紀錄伺服器:定位、視窗與尾端讀取各自以閉包回答(沒給的操作丟 `unsupported`)。
    public struct TranscriptServer: Sendable {
        public var locate: @Sendable (TranscriptLocation) throws -> TranscriptFile
        public var window: @Sendable (_ path: String, _ end: Int, _ lines: Int, _ maxBytes: Int) throws -> TranscriptChunk
        public var tail: @Sendable (_ path: String, _ cursor: Int, _ limit: Int, _ catchUp: Bool) throws -> TranscriptTailRead

        public init(
            locate: @escaping @Sendable (TranscriptLocation) throws -> TranscriptFile = { _ in throw FakeHostConnectionError.unsupported },
            window: @escaping @Sendable (String, Int, Int, Int) throws -> TranscriptChunk = { _, _, _, _ in throw FakeHostConnectionError.unsupported },
            tail: @escaping @Sendable (String, Int, Int, Bool) throws -> TranscriptTailRead = { _, _, _, _ in throw FakeHostConnectionError.unsupported }
        ) {
            self.locate = locate
            self.window = window
            self.tail = tail
        }
    }

    private var transcriptServer: TranscriptServer?

    /// 之後的定位、視窗與尾端讀取由 `server` 回答(`stub` 優先)。
    public func serveTranscript(_ server: TranscriptServer) {
        transcriptServer = server
    }

    // MARK: 事件訂閱

    /// 型別化的事件訂閱預期:`subscribeToEvents` 時依序送出 `events`(預設只有 `.subscriptionStarted`),之後保持開著,
    /// 用 `send(_:toSubscription:)` 推事件。`failure` 有值時訂閱直接失敗。
    private var subscriptionExpectations: [(events: [HerdrEvent], failure: (any Error)?, endsWith: (any Error)?)] = []
    /// app 送出的訂閱內容(依送出順序;只計型別化的訂閱)。
    public private(set) var subscribeRequests: [[EventSubscription]] = []

    public func expectSubscription(events: [HerdrEvent] = [.subscriptionStarted]) {
        subscriptionExpectations.append((events, nil, nil))
    }

    /// 送完 `events` 後串流以 `endingWith` 結束(沒有就保持開著)。
    public func expectSubscription(events: [HerdrEvent], endingWith error: (any Error)?) {
        subscriptionExpectations.append((events, nil, error))
    }

    public func expectSubscription(failure: any Error) {
        subscriptionExpectations.append(([], failure, nil))
    }

    public func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, any Error> {
        typedCalls.append("subscribeToEvents \(subscriptions.count)")
        guard !subscriptionExpectations.isEmpty else { throw FakeHostConnectionError.unexpectedRequest("events.subscribe") }
        let expectation = subscriptionExpectations.removeFirst()
        subscribeRequests.append(subscriptions)
        requests.append(Self.requestLine("events.subscribe", [
            "subscriptions": subscriptions.map { subscription -> [String: Any] in
                var entry: [String: Any] = ["event": subscription.type.rawValue]
                if let paneID = subscription.paneID { entry["pane_id"] = paneID }
                return entry
            },
        ]))
        await holdIfRequested("events.subscribe")
        if let failure = expectation.failure { throw failure }
        let (stream, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
        for event in expectation.events { continuation.yield(event) }
        if let end = expectation.endsWith { continuation.finish(throwing: end) }
        let index = subscriptionHandles.count
        subscriptionHandles.append(SubscriptionHandle(
            sendLine: { line in
                do {
                    if let event = try HerdrWireClient.decodeEventLine(line) { continuation.yield(event) }
                } catch {
                    continuation.finish(throwing: error)
                }
            },
            send: { continuation.yield($0) },
            finish: { error in
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            }))
        subscriptionsClosed.append(false)
        continuation.onTermination = { _ in Task { await self.closeSubscription(index) } }
        return stream
    }

    /// 對第 `index` 條 Agent 事件串流(從 0 起算)推一個事件。
    public func send(_ event: HerdrEvent, toSubscription index: Int) {
        subscriptionHandles[index].send(event)
    }

    /// 主機那端以 `error` 結束第 `index` 條 Agent 事件串流(例如 herdr 的 `events_lost`)。
    public func finish(subscription index: Int, throwing error: any Error) {
        subscriptionHandles[index].finish(error)
    }

    private struct SubscriptionHandle: Sendable {
        var sendLine: @Sendable (Data) -> Void
        var send: @Sendable (HerdrEvent) -> Void
        var finish: @Sendable ((any Error)?) -> Void
    }

    private var subscriptionHandles: [SubscriptionHandle] = []

    private var heldMethods: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    /// 下一個 `method` 請求先不回應，等 `releaseHeld()`(模擬讀取進行中)。
    public func hold(_ method: String) {
        heldMethods.append(method)
    }

    /// 正被擋著、還沒回應的請求數。
    public var heldCount: Int { held.count }

    /// 回應所有被擋著的請求。
    public func releaseHeld() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    /// 主機那端結束第 `index` 條 Agent 事件串流(斷線)。
    public func finish(subscription index: Int) {
        subscriptionHandles[index].finish(nil)
    }

    /// 對第 `index` 條 Agent 事件串流(從 0 起算)送出 herdr 的一行事件(JSON);錯誤 envelope 讓串流以錯誤結束。
    public func send(event: Data, toSubscription index: Int) {
        for line in event.split(separator: 0x0A) { subscriptionHandles[index].sendLine(Data(line)) }
    }

    private var holdsTranscripts = false
    private var heldTranscripts: [CheckedContinuation<Void, Never>] = []

    /// 之後的對話紀錄讀取先停住，直到 `releaseTranscripts()`(模擬很慢的讀取)。
    public func holdTranscripts() {
        holdsTranscripts = true
    }

    /// 正被停住、還沒回應的對話紀錄讀取數。
    public var heldTranscriptCount: Int { heldTranscripts.count }

    /// 放行停住的對話紀錄讀取，之後不再停。
    public func releaseTranscripts() {
        holdsTranscripts = false
        let waiting = heldTranscripts
        heldTranscripts = []
        for continuation in waiting { continuation.resume() }
    }

    /// 開過的對話紀錄追蹤(路徑與游標),依開啟順序。追蹤像 HTTPS 一樣由這裡推送：用 `send(_:toFollow:)`。
    public private(set) var transcriptFollowOpenings: [TranscriptFollowOpening] = []
    /// 每個追蹤是否已結束(app 不再讀或主機結束),依開啟順序。
    public private(set) var transcriptFollowsClosed: [Bool] = []
    private var transcriptFollows: [AsyncThrowingStream<TranscriptFollowEvent, any Error>.Continuation] = []

    public func followTranscript(path: String, from cursor: Int, pace: TranscriptFollowPace) async -> AsyncThrowingStream<TranscriptFollowEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream<TranscriptFollowEvent, any Error>.makeStream()
        let index = transcriptFollows.count
        transcriptFollowOpenings.append(TranscriptFollowOpening(path: path, cursor: cursor))
        transcriptFollows.append(continuation)
        transcriptFollowsClosed.append(false)
        continuation.onTermination = { _ in Task { await self.closeTranscriptFollow(index) } }
        return events
    }

    /// 對第 `index` 個追蹤(從 0 起算)推送一則事件;`.replaced` 之後追蹤結束(同主機連線的約定)。
    public func send(_ event: TranscriptFollowEvent, toFollow index: Int) {
        transcriptFollows[index].yield(event)
        if case .replaced = event { transcriptFollows[index].finish() }
    }

    private func closeTranscriptFollow(_ index: Int) {
        transcriptFollowsClosed[index] = true
    }

    /// 開過的 Pane 終端機，依開啟順序。
    public private(set) var paneTerminalOpenings: [PaneTerminalOpening] = []
    /// app 對 Pane 終端機送出的輸入(不含 release),依送出順序。
    public private(set) var paneTerminalInputs: [TerminalInput] = []
    private var paneTerminalExpectations: [(fixture: String, readOnly: Bool)] = []

    /// 下一次開 Pane 終端機時，回放 `session-control/<fixture>` 的 frame(不送 `terminal.closed`,保持開著);
    /// `readOnly` 是唯讀裝置(主機服務以 observe 接上)。release 時以 detached 結束。
    public func expectPaneTerminal(replaying fixture: String, readOnly: Bool = false) {
        paneTerminalExpectations.append((fixture, readOnly))
    }

    public func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection {
        paneTerminalOpenings.append(PaneTerminalOpening(target: target, columns: columns, rows: rows, takeover: takeover))
        guard !paneTerminalExpectations.isEmpty else { throw FakeHostConnectionError.unsupported }
        let expectation = paneTerminalExpectations.removeFirst()
        let (events, continuation) = AsyncStream<PaneTerminalEvent>.makeStream()
        for line in Fixtures.sessionControlLines(expectation.fixture) {
            guard let frame = Self.frame(line) else { continue }
            continuation.yield(.frame(frame))
        }
        let transport = FakePaneTerminalTransport(onSend: { input in await self.record(input) }, onRelease: {
            await self.waitWhileReleasesHeld()
            continuation.yield(.closed(.detached))
            continuation.finish()
        })
        return PaneTerminalConnection(events: events, transport: transport, isViewOnly: expectation.readOnly)
    }

    private var holdsPaneTerminalReleases = false
    private var heldReleases: [CheckedContinuation<Void, Never>] = []

    /// 之後的 Pane 終端機 release 先停住,直到 `releasePaneTerminalReleases()`(模擬放開控制的訊息還在路上)。
    public func holdPaneTerminalReleases() { holdsPaneTerminalReleases = true }

    public func releasePaneTerminalReleases() {
        holdsPaneTerminalReleases = false
        let waiting = heldReleases
        heldReleases = []
        waiting.forEach { $0.resume() }
    }

    private func waitWhileReleasesHeld() async {
        guard holdsPaneTerminalReleases else { return }
        await withCheckedContinuation { heldReleases.append($0) }
    }

    private func record(_ input: TerminalInput) {
        paneTerminalInputs.append(input)
    }

    private static func frame(_ line: Data) -> TerminalFrame? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["type"] as? String == "terminal.frame",
              let seq = object["seq"] as? Int, let width = object["width"] as? Int, let height = object["height"] as? Int,
              let base64 = object["bytes"] as? String, let bytes = Data(base64Encoded: base64) else { return nil }
        return TerminalFrame(seq: UInt64(seq), columns: width, rows: height, full: object["full"] as? Bool ?? false, bytes: bytes)
    }

    public func disconnect() async {
        disconnectCount += 1
    }

    /// 目前要求快速偵測斷線的次數(開始加一、結束減一)。
    public private(set) var quickDetectionRequests = 0
    public func beginQuickDisconnectDetection() async {
        quickDetectionRequests += 1
    }

    public func endQuickDisconnectDetection() async {
        quickDetectionRequests -= 1
    }

    private func closeSubscription(_ index: Int) {
        subscriptionsClosed[index] = true
    }
}

public enum FakeHostConnectionError: Error, Equatable {
    case unexpectedRequest(String)
    /// 這個假連線還沒有對話紀錄;Pane 終端機沒有預期(`expectPaneTerminal`)。
    case unsupported
    /// `stub` 給的值型別與操作要回的不符。
    case stubTypeMismatch(String)
}

/// 一次對話紀錄視窗讀取的參數。
public struct TranscriptWindowRead: Sendable, Equatable {
    public var path: String
    public var end: Int
    public var lines: Int
    public var maxBytes: Int
}

/// 一次對話紀錄尾端讀取的參數。
public struct TranscriptTailReadRequest: Sendable, Equatable {
    public var path: String
    public var cursor: Int
    public var limit: Int
    public var catchUp: Bool
}

/// 一次開對話紀錄追蹤的參數。
public struct TranscriptFollowOpening: Sendable, Equatable {
    public var path: String
    public var cursor: Int

    public init(path: String, cursor: Int) {
        self.path = path
        self.cursor = cursor
    }
}

/// 一次開 Pane 終端機的參數。
public struct PaneTerminalOpening: Sendable, Equatable {
    public var target: String
    public var columns: Int
    public var rows: Int
    public var takeover: Bool

    public init(target: String, columns: Int, rows: Int, takeover: Bool) {
        self.target = target
        self.columns = columns
        self.rows = rows
        self.takeover = takeover
    }
}

private struct FakePaneTerminalTransport: PaneTerminalTransport {
    let onSend: @Sendable (TerminalInput) async -> Void
    let onRelease: @Sendable () async -> Void

    func send(_ input: TerminalInput) async throws {
        await onSend(input)
    }

    func release() async {
        await onRelease()
    }
}

extension FakeHostConnection: PushPluginInstallerProviding {
    public nonisolated func pushPluginInstallers() -> (@Sendable (PushDeviceID) -> any PushPluginInstalling)? {
        guard let pushPlugins else { return nil }
        return { deviceID in pushPlugins.installer(deviceID: deviceID) }
    }
}
