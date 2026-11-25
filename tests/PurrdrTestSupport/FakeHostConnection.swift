import Foundation
import PurrdrCore
import PurrdrSSH

/// 假的主機連線：對預期的 herdr 請求(以 method 比對)回放錄製的真實回應，並記錄 app 送出的請求。
/// 上層功能的測試用它，就不必知道連線方式。
///
/// ```swift
/// let connection = FakeHostConnection()
/// await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
/// let model = AgentListModel(client: HerdrClient(connection: connection))
/// ```
///
/// 沒有預期的請求一律以 `FakeHostConnectionError.unexpectedRequest` 失敗。
public actor FakeHostConnection: HostConnection {
    /// app 送出的 herdr 請求行(含 `events.subscribe`),依送出順序。
    public private(set) var requests: [String] = []
    /// 每條 Agent 事件串流是否已被 app 關閉，依開啟順序。
    public private(set) var subscriptionsClosed: [Bool] = []
    public private(set) var disconnectCount = 0

    private var expectations: [(method: String, reply: Result<Data, any Error>)] = []
    private var subscriptions: [AsyncThrowingStream<Data, any Error>.Continuation] = []

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

    /// 預期 app 會送出 `method` 的請求，以 `reply`(錄製的回應)回應。同一 method 可預期多次，依序消耗。
    /// `events.subscribe` 的回應送完後串流保持開著，之後用 `send(event:toSubscription:)` 推事件。
    public func expect(_ method: String, reply: Data) {
        expectations.append((method, .success(reply)))
    }

    /// 預期 app 會送出 `method` 的請求，以 `failure` 失敗(例如主機服務的 `HostServiceError.paneChanged`)。
    public func expect(_ method: String, failure: any Error) {
        expectations.append((method, .failure(failure)))
    }

    /// 還沒被送出的預期請求(method)。
    public var unmetExpectations: [String] { expectations.map(\.method) }

    // MARK: - 型別化操作(ADR-0015、#594)

    private var snapshotStubs: [HostSnapshot] = []
    private var paneScreenStubs: [String] = []
    private var transcriptFileStubs: [TranscriptFile] = []
    private var transcriptChunkStubs: [TranscriptChunk] = []
    /// 型別化操作的呼叫紀錄(依序;只記操作名稱與主要參數，文字內容照原樣)。
    public private(set) var typedCalls: [String] = []

    /// 下一次 `readSnapshot()` 直接回這個值(依序消耗)。用完或沒設定就退回 herdr 請求回放(`expect("session.snapshot", …)`)。
    public func stub(snapshot: HostSnapshot) { snapshotStubs.append(snapshot) }
    /// 下一次 `readPaneScreen` 直接回這段畫面文字。
    public func stub(paneScreen: String) { paneScreenStubs.append(paneScreen) }
    /// 下一次 `locateTranscript` 直接回這個檔案。
    public func stub(transcriptFile: TranscriptFile) { transcriptFileStubs.append(transcriptFile) }
    /// 下一次 `readTranscriptWindow` 直接回這段。
    public func stub(transcriptChunk: TranscriptChunk) { transcriptChunkStubs.append(transcriptChunk) }

    public func readSnapshot() async throws -> HostSnapshot {
        typedCalls.append("readSnapshot")
        if !snapshotStubs.isEmpty { return snapshotStubs.removeFirst() }
        return try await HerdrClient(connection: self).wireSnapshot()
    }

    public func sendKeys(paneID: String, keys: [String], expecting: SendExpectation) async throws {
        typedCalls.append("sendKeys \(paneID) \(keys.joined(separator: ","))")
        try await HerdrClient(connection: self).wireSendKeys(paneID: paneID, keys: keys, expecting: expecting)
    }

    public func sendText(paneID: String, text: String, expecting: SendExpectation) async throws {
        typedCalls.append("sendText \(paneID) \(text)")
        try await HerdrClient(connection: self).wireSendText(paneID: paneID, text: text, expecting: expecting)
    }

    public func readPaneScreen(paneID: String, lines: Int, format: PaneReadFormat) async throws -> String {
        typedCalls.append("readPaneScreen \(paneID) \(lines) \(format == .ansi ? "ansi" : "text")")
        if !paneScreenStubs.isEmpty { return paneScreenStubs.removeFirst() }
        return try await HerdrClient(connection: self).wireReadPane(paneID: paneID, lines: lines, format: format)
    }

    public func locateTranscript(_ location: TranscriptLocation) async throws -> TranscriptFile {
        typedCalls.append("locateTranscript")
        if !transcriptFileStubs.isEmpty { return transcriptFileStubs.removeFirst() }
        return try await TranscriptReader(connection: self).wireLocate(location)
    }

    public func readTranscriptWindow(path: String, end: Int, lines: Int, maxBytes: Int) async throws -> TranscriptChunk {
        typedCalls.append("readTranscriptWindow \(path) \(end) \(lines) \(maxBytes)")
        if !transcriptChunkStubs.isEmpty { return transcriptChunkStubs.removeFirst() }
        return try await TranscriptReader(connection: self).wireWindow(path: path, endingAt: end, lines: lines, maxBytes: maxBytes > 0 ? maxBytes : nil)
    }

    // herdr 的結構與 Agent 操作(#595 第二批):記錄呼叫後走既有的 herdr 回放(`expect(method, reply:)`)。

    public func herdrVersion() async throws -> String {
        typedCalls.append("herdrVersion")
        return try await HerdrClient(connection: self).wirePing()
    }

    public func listIntegrations() async throws -> [AgentIntegration] {
        typedCalls.append("listIntegrations")
        return try await HerdrClient(connection: self).wireIntegrations()
    }

    public func reportPresence(paneID: String, model: String?, seq: UInt64) async throws {
        typedCalls.append("reportPresence \(paneID) \(model ?? "-") \(seq)")
        try await HerdrClient(connection: self).wireReportPresence(paneID: paneID, model: model, seq: seq)
    }

    public func renameWorkspace(_ workspaceID: String, to label: String) async throws {
        typedCalls.append("renameWorkspace \(workspaceID) \(label)")
        try await HerdrClient(connection: self).wireRenameWorkspace(workspaceID, to: label)
    }

    public func renameTab(_ tabID: String, to label: String) async throws {
        typedCalls.append("renameTab \(tabID) \(label)")
        try await HerdrClient(connection: self).wireRenameTab(tabID, to: label)
    }

    public func closeTab(_ tabID: String) async throws {
        typedCalls.append("closeTab \(tabID)")
        try await HerdrClient(connection: self).wireCloseTab(tabID)
    }

    public func closeWorkspace(_ workspaceID: String) async throws {
        typedCalls.append("closeWorkspace \(workspaceID)")
        try await HerdrClient(connection: self).wireCloseWorkspace(workspaceID)
    }

    public func createWorktree(from workspaceID: String, branch: String) async throws -> CreatedWorkspace {
        typedCalls.append("createWorktree \(workspaceID) \(branch)")
        return try await HerdrClient(connection: self).wireCreateWorktree(from: workspaceID, branch: branch)
    }

    public func createWorkspace(cwd: String, label: String?) async throws -> NewWorkspace {
        typedCalls.append("createWorkspace \(cwd) \(label ?? "-")")
        return try await HerdrClient(connection: self).wireCreateWorkspace(cwd: cwd, label: label)
    }

    public func createTab(in workspaceID: String, label: String?) async throws -> CreatedTab {
        typedCalls.append("createTab \(workspaceID) \(label ?? "-")")
        return try await HerdrClient(connection: self).wireCreateTab(in: workspaceID, label: label)
    }

    public func startAgent(_ request: AgentStartRequest) async throws -> Bool {
        typedCalls.append("startAgent \(request.kind) \(request.paneID)")
        return try await HerdrClient(connection: self).wireStartAgent(request)
    }

    public func agentLaunchState(target: String) async throws -> AgentLaunchState {
        typedCalls.append("agentLaunchState \(target)")
        return try await HerdrClient(connection: self).wireAgentLaunchState(target: target)
    }

    public func listSessions(cwd: String, agent: String) async throws -> [ResumableSession] {
        typedCalls.append("listSessions \(cwd) \(agent)")
        return try await HerdrClient(connection: self).wireListSessions(cwd: cwd, agent: agent)
    }

    public func sendPrompt(target: String, text: String, wait: Duration?, expecting: SendExpectation) async throws -> PromptReply {
        typedCalls.append("sendPrompt \(target) \(text)")
        return try await HerdrClient(connection: self).wirePrompt(target: target, text: text, wait: wait, expecting: expecting)
    }

    public func waitForAgent(target: String, until: [AgentStatus], timeout: Duration) async throws -> Bool {
        typedCalls.append("waitForAgent \(target)")
        return try await HerdrClient(connection: self).wireWaitForAgent(target: target, until: until, timeout: timeout)
    }

    public func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, any Error> {
        typedCalls.append("subscribeToEvents \(subscriptions.count)")
        return try await HerdrClient(connection: self).wireSubscribe(subscriptions)
    }

    // 對話紀錄的追蹤讀取、預覽、subagent、workflow、委派(#595 第二批 C):記錄呼叫後走既有的對話紀錄回放(`answerTranscripts`)。

    public func readTranscriptTail(path: String, from cursor: Int, limit: Int, catchUp: Bool) async throws -> TranscriptTailRead {
        typedCalls.append("readTranscriptTail \(path) \(cursor) \(limit) \(catchUp)")
        return try await TranscriptReader(connection: self).wireTail(path: path, from: cursor, limit: limit, catchUp: catchUp)
    }

    public func readTranscriptPreviews(_ requests: [PreviewRequest]) async throws -> [String: TranscriptPreviewBody] {
        typedCalls.append("readTranscriptPreviews \(requests.map(\.key).joined(separator: ","))")
        return try await TranscriptReader(connection: self).wirePreviews(requests)
    }

    public func locateSubagent(sessionFolder: String, callID: String) async throws -> String {
        typedCalls.append("locateSubagent \(callID)")
        return try await TranscriptReader(connection: self).wireLocateSubagent(sessionFolder: sessionFolder, callID: callID)
    }

    public func readWorkflow(sessionFolder: String, runID: String, knownChecksum: String?) async throws -> WorkflowRead {
        typedCalls.append("readWorkflow \(runID)")
        return try await TranscriptReader(connection: self).wireWorkflow(sessionFolder: sessionFolder, runID: runID, knownChecksum: knownChecksum)
    }

    public func readDelegationLines(path: String, callID: String, agentID: String, knownChecksum: String?) async throws -> DelegationRead {
        typedCalls.append("readDelegationLines \(callID)")
        return try await TranscriptReader(connection: self).wireDelegationLines(
            path: path, callID: callID, agentID: agentID, knownChecksum: knownChecksum)
    }

    public func herdrRequest(_ request: Data, deadline: Duration) async throws -> Data {
        let method = Self.method(of: request)
        let reply = try consume(request)
        if let index = heldMethods.firstIndex(of: method) {
            heldMethods.remove(at: index)
            await withCheckedContinuation { held.append($0) }
        }
        return reply.firstIndex(of: 0x0A).map { reply[reply.startIndex..<$0] } ?? reply
    }

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
        subscriptions[index].finish()
    }

    public func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error> {
        let reply = try consume(request)
        let (lines, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        for line in reply.split(separator: 0x0A) { continuation.yield(Data(line)) }
        let index = subscriptions.count
        subscriptions.append(continuation)
        subscriptionsClosed.append(false)
        continuation.onTermination = { _ in Task { await self.closeSubscription(index) } }
        return lines
    }

    /// 對第 `index` 條 Agent 事件串流(從 0 起算)送出一行事件。
    public func send(event: Data, toSubscription index: Int) {
        for line in event.split(separator: 0x0A) { subscriptions[index].yield(Data(line)) }
    }

    /// app 送出的對話紀錄讀取，依送出順序。
    public private(set) var transcriptRequests: [TranscriptRequest] = []
    private var transcriptAnswer: (@Sendable (TranscriptRequest) throws -> Data)?

    /// 之後的對話紀錄讀取以 `answer` 回應(格式同主機腳本的輸出)。沒設定時一律 `unsupported`。
    public func answerTranscripts(_ answer: @escaping @Sendable (TranscriptRequest) throws -> Data) {
        transcriptAnswer = answer
    }

    public func readTranscript(_ request: TranscriptRequest) async throws -> Data {
        transcriptRequests.append(request)
        if holdsTranscripts { await withCheckedContinuation { heldTranscripts.append($0) } }
        guard let transcriptAnswer else { throw FakeHostConnectionError.unsupported }
        return try transcriptAnswer(request)
    }

    private var holdsTranscripts = false
    private var heldTranscripts: [CheckedContinuation<Void, Never>] = []

    /// 之後的對話紀錄讀取先停住，直到 `releaseTranscripts()`(模擬很慢的讀取)。
    public func holdTranscripts() {
        holdsTranscripts = true
    }

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

    private static func method(of request: Data) -> String {
        (try? JSONSerialization.jsonObject(with: request) as? [String: Any])?["method"] as? String ?? ""
    }

    private func consume(_ request: Data) throws -> Data {
        let method = Self.method(of: request)
        requests.append(String(decoding: request, as: UTF8.self))
        guard let index = expectations.firstIndex(where: { $0.method == method }) else {
            throw FakeHostConnectionError.unexpectedRequest(method)
        }
        return try expectations.remove(at: index).reply.get()
    }

    private func closeSubscription(_ index: Int) {
        subscriptionsClosed[index] = true
    }
}

public enum FakeHostConnectionError: Error, Equatable {
    case unexpectedRequest(String)
    /// 這個假連線還沒有對話紀錄;Pane 終端機沒有預期(`expectPaneTerminal`)。
    case unsupported
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
