import Foundation
import PurrdrCore

/// HTTPS 連線方式的主機連線(ADR-0010):單一 WSS 連到主機服務，帶裝置權杖;herdr 請求換成主機服務協定的窄 API。
///
/// - 第一個操作時才撥號並握手(`hello`);斷線後下一個操作重新撥號，進行中的請求不重送。
/// - 權杖被拒(無效、已撤銷)後，同一個權杖不再撥號，直到存了新的權杖(重新配對):不會無限重連。
/// - 支援的 herdr method 見 `herdrRequest`;其他丟 `HostServiceError.unsupported`(後續票依協定逐一加入)。
public actor HTTPSHostConnection: HostConnection {
    private let address: HostServiceAddress
    private let deviceToken: @Sendable () throws -> String?
    private let transport: any WebSocketConnecting
    private let appVersion: String?
    private let sleep: Sleep
    private var session: HostServiceSession?
    private var welcome: HostServiceProtocol.Welcome?
    private var connecting: Task<HostServiceSession, any Error>?
    /// 被拒的權杖與原因。
    private var rejection: (deviceToken: String, error: HostServiceError)?
    /// 追蹤中的對話紀錄(路徑 → 追蹤)。見 `HTTPSTranscripts.swift`。
    var transcriptFollows: [String: TranscriptFollow] = [:]
    var nextTranscriptStream = 0

    /// - Parameters:
    ///   - deviceToken: 撥號時才讀(Keychain);`nil` 表示還沒配對。
    ///   - sleep: 期限計時用(測試注入)。
    public init(
        address: HostServiceAddress, deviceToken: @escaping @Sendable () throws -> String?,
        transport: any WebSocketConnecting = URLSessionHostServiceTransport(), appVersion: String? = nil,
        sleep: @escaping Sleep = Sleeping.task
    ) {
        self.address = address
        self.deviceToken = deviceToken
        self.transport = transport
        self.appVersion = appVersion
        self.sleep = sleep
    }

    /// 握手得到的主機服務與 herdr 伺服器資訊(連線測試顯示用)。
    public func hostServiceInfo() async throws -> HostServiceProtocol.Welcome {
        _ = try await liveSession()
        guard let welcome else { throw HostServiceError.unexpectedResponse }
        return welcome
    }

    // MARK: - herdr 單次請求

    /// 支援 `session.snapshot`(主機服務的 `agents.list`)、`ping`(握手的 herdr 資訊)、`pane.send_keys`、`pane.send_text`、`agent.prompt`。
    /// 期限到丟 `HerdrError.deadlineExceeded`(含撥號與握手)。
    public func herdrRequest(_ request: Data, deadline: Duration) async throws -> Data {
        let herdr = try HerdrRequestLine(request)
        return try await withDeadline(deadline) {
            switch herdr.method {
            case "session.snapshot":
                return try await self.snapshot(id: herdr.id)
            case "ping":
                return try await self.ping(id: herdr.id)
            case "pane.send_keys":
                return try await self.sendKeys(id: herdr.id, params: herdr.params)
            case "pane.send_text":
                return try await self.sendText(id: herdr.id, params: herdr.params)
            case "agent.prompt":
                return try await self.prompt(id: herdr.id, params: herdr.params)
            default:
                throw HostServiceError.unsupported(herdr.method)
            }
        }
    }

    private func snapshot(id: String?) async throws -> Data {
        let welcome = try await hostServiceInfo()
        let reply = try await send { .agentsList(.init(requestId: $0)) }
        guard case .agentsListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return try HerdrResponseLine.snapshot(id: id, version: welcome.herdr.version, result: result)
    }

    private func ping(id: String?) async throws -> Data {
        let welcome = try await hostServiceInfo()
        return try HerdrResponseLine.ping(id: id, herdr: welcome.herdr)
    }

    private func sendKeys(id: String?, params: Data) async throws -> Data {
        let keys = try JSONDecoder().decode(SendKeysParams.self, from: params)
        let reply = try await send { .paneSendKeys(.init(requestId: $0, paneId: keys.paneID, keys: keys.keys)) }
        guard case .paneSendKeysResult = reply else { throw HostServiceError.unexpectedResponse }
        return try HerdrResponseLine.ok(id: id)
    }

    private func sendText(id: String?, params: Data) async throws -> Data {
        let text = try JSONDecoder().decode(SendTextParams.self, from: params)
        let reply = try await send { .paneSendText(.init(requestId: $0, paneId: text.paneID, text: text.text)) }
        guard case .paneSendTextResult = reply else { throw HostServiceError.unexpectedResponse }
        return try HerdrResponseLine.ok(id: id)
    }

    private func prompt(id: String?, params: Data) async throws -> Data {
        let prompt = try JSONDecoder().decode(PromptParams.self, from: params)
        let wait = prompt.wait.map { wait in
            HostServiceProtocol.PromptWait(until: wait.until.compactMap(HostServiceProtocol.AgentStatus.init(rawValue:)), timeoutMs: wait.timeoutMs)
        }
        let reply = try await send { .agentPrompt(.init(requestId: $0, paneId: prompt.target, text: prompt.text, wait: wait)) }
        guard case .agentPromptResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return try HerdrResponseLine.prompted(id: id, delivery: result.delivery)
    }

    /// 握手時主機服務回報的唯讀。
    public func isReadOnlyDevice() async throws -> Bool {
        try await hostServiceInfo().readOnly
    }

    // MARK: - Agent 事件串流

    /// `events.subscribe`:目前主機服務還不推送事件(#58),所以回 ack 後保持開著，直到連線結束(以結束原因失敗)
    /// 或呼叫端不再讀。上層據此在重連時重讀 snapshot。
    public func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error> {
        let herdr = try HerdrRequestLine(request)
        guard herdr.method == "events.subscribe" else { throw HostServiceError.unsupported(herdr.method) }
        let session = try await withDeadline(HostCommandDeadline.standard) { try await self.liveSession() }
        let (lines, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(try HerdrResponseLine.subscriptionStarted(id: herdr.id))
        let watcher = Task {
            let ending = await session.waitUntilClosed()
            self.noteEnding(ending, of: session)
            continuation.finish(throwing: ending)
        }
        continuation.onTermination = { _ in watcher.cancel() }
        return lines
    }

    // MARK: - 對話紀錄

    /// 定位、視窗與尾端追蹤(#59);列表預覽、subagent、workflow、委派的讀取丟 `unsupported`。
    public func readTranscript(_ request: TranscriptRequest) async throws -> Data {
        try await transcript(request)
    }

    /// 請主機服務停止追蹤這個對話紀錄。
    public func stopFollowingTranscript(path: String) async {
        guard let follow = transcriptFollows.removeValue(forKey: path) else { return }
        await stopFollowing(follow)
    }

    // MARK: - 尚未支援

    public func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection {
        throw HostServiceError.unsupported("pane terminal")
    }

    public func disconnect() async {
        let current = session
        session = nil
        welcome = nil
        // 主機服務在連線結束時停止這條連線的所有追蹤。
        transcriptFollows = [:]
        await current?.close()
    }

    // MARK: - 連線

    /// 送出請求;權杖被拒時記下來。
    func send(_ make: @Sendable (String) -> HostServiceProtocol.ClientMessage) async throws -> HostServiceProtocol.ServerMessage {
        try await send(on: liveSession(), make)
    }

    /// 在這條連線送出請求(呼叫端先在連線上準備好，例如開好串流)。
    func send(
        on session: HostServiceSession, _ make: @Sendable (String) -> HostServiceProtocol.ClientMessage
    ) async throws -> HostServiceProtocol.ServerMessage {
        let reply: HostServiceProtocol.ServerMessage
        do {
            reply = try await session.request(make)
        } catch {
            noteEnding(error, of: session)
            throw error
        }
        if case .errorMessage(let error) = reply { throw Self.error(for: error) }
        return reply
    }

    func liveSession() async throws -> HostServiceSession {
        if let session, await session.isOpen { return session }
        if let connecting { return try await connecting.value }
        guard let token = try deviceToken() else { throw HostServiceError.notPaired }
        if let rejection, rejection.deviceToken == token { throw rejection.error }
        let opening = Task { try await self.open(deviceToken: token) }
        connecting = opening
        defer { connecting = nil }
        do {
            let opened = try await opening.value
            session = opened
            return opened
        } catch let error as HostServiceError where error.requiresPairing {
            rejection = (token, error)
            throw error
        }
    }

    /// 撥號並握手。握手有自己的期限，卡住的主機服務不會讓之後的操作一直等。
    private func open(deviceToken token: String) async throws -> HostServiceSession {
        let socket = try await transport.connect(to: address.webSocketURL, bearerToken: token)
        let opened = HostServiceSession(socket: socket, deviceToken: token)
        await opened.start()
        let appVersion = appVersion
        let reply: HostServiceProtocol.ServerMessage
        do {
            reply = try await withDeadline(HostCommandDeadline.standard) {
                try await opened.request { .hello(.init(requestId: $0, protocolVersion: HostServiceProtocol.version, appVersion: appVersion)) }
            }
        } catch HerdrError.deadlineExceeded {
            await opened.close()
            throw HostServiceError.unreachable
        } catch {
            await opened.close()
            throw error
        }
        switch reply {
        case .welcome(let welcome):
            self.welcome = welcome
            return opened
        case .errorMessage(let error):
            await opened.close()
            throw Self.error(for: error)
        default:
            await opened.close()
            throw HostServiceError.unexpectedResponse
        }
    }

    /// 連線結束：權杖被拒就記下(之後同一個權杖不再撥號)。
    private func noteEnding(_ error: any Error, of ended: HostServiceSession) {
        if let rejected = error as? HostServiceError, rejected.requiresPairing {
            rejection = (ended.deviceToken, rejected)
        }
        if session === ended, !(error is CancellationError) { session = nil }
    }

    /// 主機服務的錯誤訊息換成 app 的錯誤。herdr 自己的錯誤保留 herdr 的碼與原文。
    static func error(for message: HostServiceProtocol.ErrorMessage) -> any Error {
        switch message.code {
        case .deviceTokenInvalid: HostServiceError.deviceTokenInvalid
        case .deviceTokenRevoked: HostServiceError.deviceTokenRevoked
        case .protocolVersionUnsupported: HostServiceError.protocolVersionUnsupported(supported: message.supportedProtocolVersions ?? [])
        case .herdrUnavailable: HostServiceError.herdrUnavailable
        case .herdrCapabilityMissing: HostServiceError.herdrCapabilityMissing
        case .herdrError: HerdrError.herdr(code: message.herdrCode ?? "herdr_error", message: message.message)
        case .readOnlyDevice: HostServiceError.readOnlyDevice
        case .pairingCodeInvalid: HostServiceError.pairingCodeInvalid
        case .pairingCodeExpired: HostServiceError.pairingCodeExpired
        case .transcriptAbsent: TranscriptReadError.absent
        case .transcriptUnreadable: TranscriptReadError.unreadable
        case .transcriptAmbiguous: TranscriptReadError.ambiguous
        case .transcriptCompressed: TranscriptReadError.compressed
        case .transcriptNotAllowed: TranscriptReadError.invalidReference
        case .transcriptUnsupported: HostServiceError.unsupported("transcript")
        case .invalidMessage, .handshakeRequired, .internalError: HostServiceError.unexpectedResponse
        }
    }

    /// 期限到丟 `HerdrError.deadlineExceeded`;外層取消丟 `CancellationError`。
    func withDeadline<Value: Sendable>(
        _ deadline: Duration, _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value?.self) { group in
            group.addTask { try await operation() }
            group.addTask { [sleep] in
                try await sleep(deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                try Task.checkCancellation()
                throw HerdrError.deadlineExceeded
            }
            return value
        }
    }

    private struct SendTextParams: Decodable {
        var paneID: String
        var text: String

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case text
        }
    }

    /// herdr `agent.prompt` 的 params(`HerdrClient` 送出的形狀)。
    private struct PromptParams: Decodable {
        var target: String
        var text: String
        var wait: Wait?

        struct Wait: Decodable {
            var until: [String]
            var timeoutMs: Int

            enum CodingKeys: String, CodingKey {
                case until
                case timeoutMs = "timeout_ms"
            }
        }
    }

    private struct SendKeysParams: Decodable {
        var paneID: String
        var keys: [String]

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case keys
        }
    }
}

/// app 送出的一行 herdr 請求(`HerdrClient` 的 wire format)。
struct HerdrRequestLine {
    var id: String?
    var method: String
    /// `params` 的原始 JSON(沒有時是 `{}`)。
    var params: Data

    init(_ line: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let method = object["method"] as? String
        else { throw HerdrError.malformedResponse }
        id = object["id"] as? String
        self.method = method
        params = try JSONSerialization.data(withJSONObject: object["params"] ?? [String: Any]())
    }
}

/// 把主機服務的回應換成 herdr 的回應行，`HerdrClient` 照原本的方式解析。
enum HerdrResponseLine {
    static func snapshot(id: String?, version: String, result: HostServiceProtocol.AgentsListResult) throws -> Data {
        let snapshot = Snapshot(
            version: version,
            workspaces: result.workspaces.map { Snapshot.Workspace(workspaceID: $0.workspaceId, label: $0.label) },
            agents: result.agents.map { agent in
                Snapshot.Agent(
                    paneID: agent.paneId, workspaceID: agent.workspaceId, tabID: agent.tabId, agent: agent.agent,
                    agentStatus: agent.status.rawValue, terminalTitleStripped: agent.title, cwd: agent.cwd,
                    agentSession: agent.session.map { Snapshot.Session(kind: $0.kind, value: $0.value) })
            })
        return try encode(Envelope(id: id, result: SnapshotResult(snapshot: snapshot)))
    }

    static func ping(id: String?, herdr: HostServiceProtocol.HerdrServer) throws -> Data {
        try encode(Envelope(id: id, result: Ping(version: herdr.version, protocol: herdr.protocol)))
    }

    static func ok(id: String?) throws -> Data {
        try encode(Envelope(id: id, result: Typed(type: "ok")))
    }

    /// `agent.prompt` 成功;`delivery` 照主機回報(沒有就省略)。
    static func prompted(id: String?, delivery: String?) throws -> Data {
        try encode(Envelope(id: id, result: Prompted(type: "agent_prompted", delivery: delivery)))
    }

    static func subscriptionStarted(id: String?) throws -> Data {
        try encode(Envelope(id: id, result: Typed(type: "subscription_started")))
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private struct Envelope<Result: Encodable>: Encodable {
        var id: String?
        var result: Result
    }

    private struct Typed: Encodable {
        var type: String
    }

    private struct Prompted: Encodable {
        var type: String
        var delivery: String?
    }

    private struct Ping: Encodable {
        var version: String
        var `protocol`: Int
    }

    private struct SnapshotResult: Encodable {
        var snapshot: Snapshot
    }

    private struct Snapshot: Encodable {
        var version: String
        var workspaces: [Workspace]
        var agents: [Agent]

        struct Workspace: Encodable {
            var workspaceID: String
            var label: String

            enum CodingKeys: String, CodingKey {
                case workspaceID = "workspace_id"
                case label
            }
        }

        struct Agent: Encodable {
            var paneID: String
            var workspaceID: String
            var tabID: String
            var agent: String?
            var agentStatus: String
            var terminalTitleStripped: String?
            var cwd: String?
            var agentSession: Session?

            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
                case workspaceID = "workspace_id"
                case tabID = "tab_id"
                case agent
                case agentStatus = "agent_status"
                case terminalTitleStripped = "terminal_title_stripped"
                case cwd
                case agentSession = "agent_session"
            }
        }

        struct Session: Encodable {
            var kind: String
            var value: String
        }
    }
}
