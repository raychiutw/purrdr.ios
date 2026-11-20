import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import PurrdrCore
import PurrdrTestSupport
import Synchronization

/// 假的主機服務：本機 127.0.0.1 隨機埠上的 HTTP + WebSocket 伺服器，照協定(`vendor/purrdr-host/protocol/host-service.schema.json`)回應。
///
/// 行為仿照真正的主機服務(raychiutw/purrdr.host 的 `host-service/`):先完成 WebSocket 升級再驗證 `Authorization: Bearer`,
/// 權杖無效或已撤銷時送 `error` 後以 close code 4401 關閉;每個訊息都重新驗證(`revoke(_:)` 立即生效)。
/// 回應內容來自 `vendor/purrdr-host/protocol/examples/`(兩端共用的範例，從 purrdr.host 同步)。
final class FakeHostService: Sendable {
    /// `agents.list` 的回應方式。
    enum AgentsReply: Sendable {
        /// `server.agents-list-result.json` 的內容。
        case example
        /// 範例內容，但換掉某些 Pane 的狀態(pane id → 狀態)。
        case statuses([String: String])
        /// 錯誤訊息(`code` 是協定的錯誤碼)。
        case error(code: String, message: String = "failed", herdrCode: String? = nil)
        /// 一直不回應。
        case silent
    }

    /// `pane.terminal.open` 的回應方式(仿照主機服務轉接 `herdr terminal session control`)。
    enum PaneTerminalReply: Sendable {
        /// 回放 `session-control/<錄製檔>` 的 stdout:frame 依序轉成 `pane.terminal.frame`;
        /// 錄製檔最後是 `detached` 時等 app 送 `pane.terminal.close` 才結束，沒有 `terminal.closed` 時以 disconnected 結束。
        case replay(String)
        /// herdr 沒跑起來。
        case failed(exitCode: Int, message: String)
    }

    /// `events.subscribe` 的回應方式。
    enum SubscribeReply: Sendable {
        /// 接受，之後用 `pushEvent` 推事件。
        case accept
        /// 接受但不回應結果(結果還在路上時呼叫端放棄)。
        case acceptWithoutReply
        case error(code: String, message: String = "failed", herdrCode: String? = nil)
    }

    struct Log: Sendable {
        /// WebSocket 連線數。
        var connections = 0
        /// 每條 WebSocket 連線的 `Authorization` 標頭。
        var authorizations: [String?] = []
        /// 收到的 WebSocket 訊息(JSON 文字)。
        var messages: [String] = []
        /// `POST /v1/pair` 的本文。
        var pairRequests: [Data] = []
        /// `POST /v1/revoke` 的 `Authorization` 標頭。
        var revokeAuthorizations: [String?] = []
        /// 收到的 WebSocket ping 數。
        var pings = 0
        /// 送給 app 的 WebSocket 文字訊息(回應與推送)。
        var sent: [String] = []
    }

    struct Settings: Sendable {
        var validTokens: Set<String> = ["token-ok"]
        var revokedTokens: Set<String> = []
        var readOnlyTokens: Set<String> = []
        var supportedProtocolVersions: [Int] = [HostServiceProtocol.version]
        var agentsReply: AgentsReply = .example
        var paneTerminalReply: PaneTerminalReply = .replay("01-handshake-echo-release.stdout.ndjson")
        var subscribeReply: SubscribeReply = .accept
        /// `false` 時不回 pong(模擬卡住的連線)。
        var answersPings = true
        /// 這個配對碼換得 `pairedToken`。
        var pairingCode = "K7QM-2XPA"
        var expiredPairingCode = "OLD0-CODE"
        var pairedToken = "token-paired"
        /// 對話紀錄訊息(`transcript.*`)的回應：訊息種類 → JSON 物件(不含 `request_id`;請求帶 `stream_id` 時換上請求的)。
        var transcriptReplies: [String: String] = [:]
        /// 主機取檔訊息(`file.stat`／`file.read`)的回應：訊息種類 → 依序回的 JSON 物件(不含 `request_id`)。
        var fileReplies: [String: [String]] = [:]
        /// `agent.prompt` 成功時回報的 `delivery`。
        var promptDelivery: String?
        /// 有值時 `agent.prompt` 以 `herdr_error` 失敗，帶這個 herdr 錯誤碼。
        var promptHerdrError: String?
        /// `welcome` 回報的主機服務版本;`nil` 是範例的值。
        var hostServiceVersion: String?
        /// `host_service.status` 回的範例檔(#290)。
        var hostServiceStatusExample = "server.host-service-status-result.json"
        /// 有值時 `host_service.status` 改回這個 JSON 物件(不含 `request_id`)。
        var hostServiceStatusReply: String?
        /// `host_service.update` 回的範例檔。
        var hostServiceUpdateExample = "server.host-service-update-result.json"
        /// 有值時 `host_service.update` 改回這個 JSON 物件(不含 `request_id`)。
        var hostServiceUpdateReply: String?
        /// 有值時 `host_service.*` 以這個錯誤碼失敗。
        var hostServiceErrorCode: String?
    }

    let port: Int
    private let channel: any Channel
    private let state: Mutex<(log: Log, settings: Settings, sockets: [any Channel], streams: [EventStream])>
    /// 等 app 關閉才送出的 `terminal.closed`(以串流識別碼為 key)。
    private let pendingTerminalClosings = Mutex<[String: String]>([:])

    /// 開著的事件串流。
    private struct EventStream {
        var socket: any Channel
        var streamID: String
    }

    var address: HostServiceAddress { HostServiceAddress("http://127.0.0.1:\(port)")! }
    var log: Log { state.withLock { $0.log } }
    /// 開著的事件串流識別碼。
    var openStreams: [String] { state.withLock { $0.streams.map(\.streamID) } }

    private init(port: Int, channel: any Channel, settings: Settings) {
        self.port = port
        self.channel = channel
        state = Mutex((Log(), settings, [], []))
    }

    /// 對每條開著的事件串流推一個 herdr 事件。
    func pushEvent(_ name: String, paneID: String? = nil) {
        for stream in state.withLock({ $0.streams }) {
            var event: [String: Any] = ["type": "events.event", "stream_id": stream.streamID, "event": name]
            event["pane_id"] = paneID
            _ = stream.socket.writeAndFlush(textFrame(Self.json(event), on: stream.socket))
        }
    }

    /// 主機端結束每條事件串流;`code` 有值表示失敗(例如 herdr 的 `events_lost`)。
    func endStreams(code: String? = nil, message: String? = nil, herdrCode: String? = nil) {
        let streams = state.withLock { state in
            defer { state.streams = [] }
            return state.streams
        }
        for stream in streams {
            var ended: [String: Any] = ["type": "events.ended", "stream_id": stream.streamID]
            ended["code"] = code
            ended["message"] = message
            ended["herdr_code"] = herdrCode
            _ = stream.socket.writeAndFlush(textFrame(Self.json(ended), on: stream.socket))
        }
    }

    fileprivate func receivedPing() -> Bool {
        state.withLock {
            $0.log.pings += 1
            return $0.settings.answersPings
        }
    }

    private func textFrame(_ text: String, on socket: any Channel) -> WebSocketFrame {
        recordSent(text)
        return WebSocketFrame(fin: true, opcode: .text, data: socket.allocator.buffer(string: text))
    }

    fileprivate func recordSent(_ text: String) {
        state.withLock { $0.log.sent.append(text) }
    }

    static func start(_ settings: Settings = Settings()) async throws -> FakeHostService {
        let box = ServerBox()
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, head in
                        guard head.uri == "/v1/ws" else { return channel.eventLoop.makeSucceededFuture(nil) }
                        // 升級前先移除 HTTP handler,升級後的 WebSocket 位元組才不會流到它。
                        return channel.pipeline.removeHandler(name: "fake-http").map { HTTPHeaders() }
                    },
                    upgradePipelineHandler: { channel, head in
                        let authorization = head.headers.first(name: "Authorization")
                        return channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                WebSocketHandler(server: box.server!, authorization: authorization))
                        }
                    })
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
                    try channel.pipeline.syncOperations.addHandler(HTTPHandler(server: box.server!), name: "fake-http")
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let server = FakeHostService(port: channel.localAddress!.port!, channel: channel, settings: settings)
        box.server = server
        return server
    }

    func stop() async {
        let sockets = state.withLock { $0.sockets }
        for socket in sockets { try? await socket.close() }
        try? await channel.close()
    }

    /// 在主機上撤銷權杖：之後那條連線的下一個訊息被拒。
    func revoke(_ token: String) {
        state.withLock {
            $0.settings.validTokens.remove(token)
            $0.settings.revokedTokens.insert(token)
        }
    }

    func update(_ change: @Sendable (inout Settings) -> Void) {
        state.withLock { change(&$0.settings) }
    }

    /// 主機服務主動推送一個訊息(例如 `transcript.update`)給所有連線。
    func push(_ text: String) async throws {
        let sockets = state.withLock { $0.sockets }
        for socket in sockets {
            recordSent(text)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: socket.allocator.buffer(string: text))
            try await socket.writeAndFlush(frame)
        }
    }

    /// 收到的 WebSocket 訊息中種類是 `type` 的(解析成 JSON 物件)。
    func messages(ofType type: String) -> [[String: Any]] {
        log.messages.compactMap { text in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["type"] as? String == type else { return nil }
            return object
        }
    }

    /// 切斷所有 WebSocket 連線(不送 close frame,模擬網路中斷)。
    func dropConnections() async {
        let sockets = state.withLock { state in
            defer {
                state.sockets = []
                state.streams = []
            }
            return state.sockets
        }
        for socket in sockets { try? await socket.close() }
    }

    // MARK: - 回應

    enum Outgoing: Equatable {
        case text(String)
        case close(code: UInt16)
    }

    fileprivate func connected(_ socket: any Channel, authorization: String?) -> [Outgoing] {
        state.withLock {
            $0.log.connections += 1
            $0.log.authorizations.append(authorization)
            $0.sockets.append(socket)
        }
        return rejection(for: authorization) ?? []
    }

    fileprivate func respond(to text: String, authorization: String?, socket: any Channel) -> [Outgoing] {
        state.withLock { $0.log.messages.append(text) }
        if let rejection = rejection(for: authorization) { return rejection }
        let settings = state.withLock { $0.settings }
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = message["type"] as? String else { return [.text(Self.error(nil, "invalid_message"))] }
        let requestID = message["request_id"] as? String
        switch type {
        case "hello":
            let version = message["protocol_version"] as? Int ?? 0
            guard settings.supportedProtocolVersions.contains(version) else {
                return [.text(Self.json([
                    "type": "error", "request_id": requestID as Any, "code": "protocol_version_unsupported",
                    "message": "protocol version \(version) is not supported",
                    "supported_protocol_versions": settings.supportedProtocolVersions,
                ]))]
            }
            let readOnly = Self.token(authorization).map(settings.readOnlyTokens.contains) ?? false
            var changing: [String: Any] = ["read_only": readOnly]
            if let version = settings.hostServiceVersion { changing["host_service_version"] = version }
            return [.text(Self.example("server.welcome.json", requestID: requestID, changing: changing))]
        case "agents.list":
            switch settings.agentsReply {
            case .example: return [.text(Self.example("server.agents-list-result.json", requestID: requestID))]
            case .statuses(let statuses): return [.text(Self.agents(requestID: requestID, statuses: statuses))]
            case .error(let code, let text, let herdrCode): return [.text(Self.error(requestID, code, message: text, herdrCode: herdrCode))]
            case .silent: return []
            }
        case "events.subscribe":
            let streamID = message["stream_id"] as? String ?? ""
            switch settings.subscribeReply {
            case .accept:
                state.withLock { $0.streams.append(EventStream(socket: socket, streamID: streamID)) }
                return [.text(Self.json(["type": "events.subscribe.result", "request_id": requestID as Any, "stream_id": streamID]))]
            case .acceptWithoutReply:
                state.withLock { $0.streams.append(EventStream(socket: socket, streamID: streamID)) }
                return []
            case .error(let code, let text, let herdrCode):
                return [.text(Self.error(requestID, code, message: text, herdrCode: herdrCode))]
            }
        case "events.unsubscribe":
            let streamID = message["stream_id"] as? String
            state.withLock { $0.streams.removeAll { $0.socket === socket && $0.streamID == streamID } }
            return [.text(Self.json(["type": "events.unsubscribe.result", "request_id": requestID as Any]))]
        case let transcript where transcript.hasPrefix("transcript."):
            guard let reply = settings.transcriptReplies[transcript],
                  var object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else {
                return [.text(Self.error(requestID, "invalid_message"))]
            }
            object["request_id"] = requestID
            if let streamID = message["stream_id"] { object["stream_id"] = streamID }
            return [.text(Self.json(object))]
        case "file.stat", "file.read":
            // 依序取用;只剩一則時一直回它。
            let reply = state.withLock { state -> String? in
                guard let queue = state.settings.fileReplies[type], let first = queue.first else { return nil }
                if queue.count > 1 { state.settings.fileReplies[type] = Array(queue.dropFirst()) }
                return first
            }
            guard let reply, var object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else {
                return [.text(Self.error(requestID, "invalid_message"))]
            }
            object["request_id"] = requestID
            return [.text(Self.json(object))]
        case "pane.send_keys", "pane.send_text", "agent.prompt":
            if let token = Self.token(authorization), settings.readOnlyTokens.contains(token) {
                return [.text(Self.error(requestID, "read_only_device"))]
            }
            if type == "agent.prompt", let herdrCode = settings.promptHerdrError {
                return [.text(Self.error(requestID, "herdr_error", message: herdrCode, herdrCode: herdrCode))]
            }
            var result: [String: Any] = ["type": type + ".result", "request_id": requestID as Any]
            if type == "agent.prompt" { result["delivery"] = settings.promptDelivery }
            return [.text(Self.json(result))]
        case "host_service.status", "host_service.update", "host_service.set_auto_update":
            return [.text(hostServiceReply(type, message: message, requestID: requestID, authorization: authorization, settings: settings))]
        case "pane.terminal.open":
            let readOnly = Self.token(authorization).map(settings.readOnlyTokens.contains) == true
            return openTerminal(streamID: requestID ?? "", readOnly: readOnly, reply: settings.paneTerminalReply)
        case "pane.terminal.input", "pane.terminal.resize", "pane.terminal.scroll":
            if let token = Self.token(authorization), settings.readOnlyTokens.contains(token) {
                return [.text(Self.error(nil, "read_only_device"))]
            }
            return []
        case "pane.terminal.close":
            let streamID = message["stream_id"] as? String ?? ""
            guard let reason = pendingTerminalClosings.withLock({ $0.removeValue(forKey: streamID) }) else { return [] }
            return [.text(Self.terminalClosed(streamID, ending: "closed", reason: reason))]
        default:
            return [.text(Self.error(requestID, "invalid_message"))]
        }
    }

    /// 管理主機服務(#290):寫入類(`update`、`set_auto_update`)唯讀裝置被拒。
    private func hostServiceReply(
        _ type: String, message: [String: Any], requestID: String?, authorization: String?, settings: Settings
    ) -> String {
        if type != "host_service.status", let token = Self.token(authorization), settings.readOnlyTokens.contains(token) {
            return Self.error(requestID, "read_only_device")
        }
        if let code = settings.hostServiceErrorCode { return Self.error(requestID, code) }
        switch type {
        case "host_service.status":
            return Self.reply(settings.hostServiceStatusReply, requestID: requestID)
                ?? Self.example(settings.hostServiceStatusExample, requestID: requestID)
        case "host_service.update":
            return Self.reply(settings.hostServiceUpdateReply, requestID: requestID)
                ?? Self.example(settings.hostServiceUpdateExample, requestID: requestID)
        default:
            return Self.json([
                "type": "host_service.set_auto_update.result", "request_id": requestID as Any, "auto_update": message["enabled"] as? Bool ?? false,
            ])
        }
    }

    /// 換上請求識別碼的 JSON 物件;`nil` 或讀不懂時 `nil`。
    private static func reply(_ object: String?, requestID: String?) -> String? {
        guard let object, var parsed = try? JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any] else { return nil }
        parsed["request_id"] = requestID
        return json(parsed)
    }

    /// 主機服務對錄製的 herdr stdout 做的轉接:frame 欄位原樣、加上串流識別碼。
    private func openTerminal(streamID: String, readOnly: Bool, reply: PaneTerminalReply) -> [Outgoing] {
        var outgoing: [Outgoing] = [.text(Self.json([
            "type": "pane.terminal.open.result", "request_id": streamID, "stream_id": streamID, "read_only": readOnly,
        ]))]
        switch reply {
        case .failed(let exitCode, let message):
            outgoing.append(.text(Self.json([
                "type": "pane.terminal.closed", "stream_id": streamID, "ending": "failed", "exit_code": exitCode, "message": message,
            ])))
        case .replay(let fixture):
            var closedReason: String?
            for line in Fixtures.sessionControlLines(fixture) {
                guard let herdr = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                switch herdr["type"] as? String {
                case "terminal.frame":
                    var frame = herdr
                    frame["type"] = "pane.terminal.frame"
                    frame["stream_id"] = streamID
                    frame["encoding"] = nil
                    outgoing.append(.text(Self.json(frame)))
                case "terminal.closed":
                    closedReason = herdr["reason"] as? String ?? ""
                default:
                    continue
                }
            }
            switch closedReason {
            case "detached":
                pendingTerminalClosings.withLock { $0[streamID] = "detached" }
            case let reason?:
                outgoing.append(.text(Self.terminalClosed(streamID, ending: "closed", reason: reason)))
            case nil:
                outgoing.append(.text(Self.terminalClosed(streamID, ending: "disconnected")))
            }
        }
        return outgoing
    }

    private static func terminalClosed(_ streamID: String, ending: String, reason: String? = nil) -> String {
        var object: [String: Any] = ["type": "pane.terminal.closed", "stream_id": streamID, "ending": ending]
        object["reason"] = reason
        return json(object)
    }

    fileprivate func pair(_ body: Data) -> (HTTPResponseStatus, String) {
        state.withLock { $0.log.pairRequests.append(body) }
        let settings = state.withLock { $0.settings }
        let code = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["pairing_code"] as? String
        switch code {
        case settings.pairingCode:
            return (.ok, Self.json(["device_id": "5f3a9c2e81d04b7a", "device_token": settings.pairedToken, "read_only": false]))
        case settings.expiredPairingCode:
            return (.unauthorized, Self.error(nil, "pairing_code_expired"))
        default:
            return (.unauthorized, Self.error(nil, "pairing_code_invalid"))
        }
    }

    fileprivate func revokeSelf(authorization: String?) -> (HTTPResponseStatus, String) {
        state.withLock { $0.log.revokeAuthorizations.append(authorization) }
        if let token = Self.token(authorization), state.withLock({ $0.settings.validTokens.contains(token) }) {
            revoke(token)
            return (.noContent, "")
        }
        return (.unauthorized, Self.error(nil, "device_token_invalid"))
    }

    private func rejection(for authorization: String?) -> [Outgoing]? {
        let settings = state.withLock { $0.settings }
        let token = Self.token(authorization)
        if let token, settings.validTokens.contains(token) { return nil }
        let code = token.map(settings.revokedTokens.contains) == true ? "device_token_revoked" : "device_token_invalid"
        return [.text(Self.error(nil, code)), .close(code: 4401)]
    }

    private static func token(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        return String(authorization.dropFirst("Bearer ".count))
    }

    static let examplesDirectory = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "vendor/purrdr-host/protocol/examples")

    /// 協定範例，換上這次的請求識別碼。
    private static func example(_ name: String, requestID: String?, changing changes: [String: Any] = [:]) -> String {
        let data = (try? Data(contentsOf: examplesDirectory.appending(path: name))) ?? Data()
        var object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        object.merge(changes) { _, changed in changed }
        object["request_id"] = requestID
        return json(object)
    }

    /// Agent 列表範例，換掉指定 Pane 的狀態;範例沒有的 Pane 以第一個 Agent 為樣本加上(session id 依序編號)。
    private static func agents(requestID: String?, statuses: [String: String]) -> String {
        let data = (try? Data(contentsOf: examplesDirectory.appending(path: "server.agents-list-result.json"))) ?? Data()
        var object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        object["request_id"] = requestID
        var agents = object["agents"] as? [[String: Any]] ?? []
        let known = Set(agents.compactMap { $0["pane_id"] as? String })
        if let template = agents.first {
            for (index, paneID) in statuses.keys.filter({ !known.contains($0) }).sorted().enumerated() {
                var agent = template
                agent["pane_id"] = paneID
                if var session = agent["session"] as? [String: Any] {
                    session["value"] = String(format: "00000000-0000-0000-0000-%012d", 100 + index)
                    agent["session"] = session
                }
                agents.append(agent)
            }
        }
        object["agents"] = agents.map { agent in
            var agent = agent
            if let paneID = agent["pane_id"] as? String, let status = statuses[paneID] { agent["status"] = status }
            return agent
        }
        return json(object)
    }

    private static func error(_ requestID: String?, _ code: String, message: String = "failed", herdrCode: String? = nil) -> String {
        var object: [String: Any] = ["type": "error", "code": code, "message": message]
        object["request_id"] = requestID
        object["herdr_code"] = herdrCode
        return json(object)
    }

    private static func json(_ object: [String: Any]) -> String {
        // `nil` 的 optional(例如沒有請求識別碼)不寫出來。
        let cleaned = object.compactMapValues { value -> Any? in
            let mirror = Mirror(reflecting: value)
            return mirror.displayStyle == .optional ? mirror.children.first?.value : value
        }
        let data = (try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// 伺服器建好之前就要建立 handler 的工廠：先放一個盒子，bind 完再填。
private final class ServerBox: @unchecked Sendable {
    var server: FakeHostService?
}

/// `POST /v1/pair`、`POST /v1/revoke`。
private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: FakeHostService
    private var head: HTTPRequestHead?
    private var body = Data()

    init(server: FakeHostService) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(var buffer):
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            guard let head else { return }
            let (status, text): (HTTPResponseStatus, String) = switch (head.method, head.uri) {
            case (.POST, "/v1/pair"): server.pair(body)
            case (.POST, "/v1/revoke"): server.revokeSelf(authorization: head.headers.first(name: "Authorization"))
            default: (.notFound, "")
            }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: String(text.utf8.count))
            if !text.isEmpty { headers.add(name: "Content-Type", value: "application/json") }
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)
            if !text.isEmpty {
                context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: text)))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            self.head = nil
        }
    }
}

/// 一條 app 的 WebSocket 連線。
private final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let server: FakeHostService
    private let authorization: String?

    init(server: FakeHostService, authorization: String?) {
        self.server = server
        self.authorization = authorization
    }

    func handlerAdded(context: ChannelHandlerContext) {
        send(server.connected(context.channel, authorization: authorization), context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var payload = frame.unmaskedData
            let text = payload.readString(length: payload.readableBytes) ?? ""
            send(server.respond(to: text, authorization: authorization, socket: context.channel), context: context)
        case .connectionClose:
            context.close(promise: nil)
        case .ping:
            guard server.receivedPing() else { return }
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        default:
            break
        }
    }

    private func send(_ outgoing: [FakeHostService.Outgoing], context: ChannelHandlerContext) {
        for item in outgoing {
            switch item {
            case .text(let text):
                server.recordSent(text)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: context.channel.allocator.buffer(string: text))
                context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
            case .close(let code):
                var data = context.channel.allocator.buffer(capacity: 2)
                data.write(webSocketErrorCode: .unknown(code))
                context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: data)), promise: nil)
            }
        }
    }
}
