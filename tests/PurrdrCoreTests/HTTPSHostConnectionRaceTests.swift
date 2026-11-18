import Foundation
import PurrdrCore
@testable import PurrdrHTTPS
import Synchronization
import Testing

/// 主機服務連線的時序競態(#153):以腳本化的 WebSocket 與計時固定先後順序，不靠真網路的運氣。
@Suite("HTTPS 主機連線的時序")
struct HTTPSHostConnectionRaceTests {
    @Test("主機已送出拒絕、app 的握手才送失敗：仍以權杖被拒的種類結束，之後不再撥號")
    func rejectionWinsOverFailedSend() async throws {
        let transport = RejectingTransport()
        let client = HerdrClient(connection: HTTPSHostConnection(address: Self.address, deviceToken: { "token-ok" }, transport: transport))

        await #expect(throws: HostServiceError.deviceTokenRevoked) { try await client.snapshot() }
        await #expect(throws: HostServiceError.deviceTokenRevoked) { try await client.snapshot() }

        #expect(transport.connections == 1)
    }

    @Test("取消時操作已拿到結果：不丟掉結果，交給呼叫端收尾(例如關掉主機已開的串流)")
    func deadlineKeepsResultArrivingAfterCancellation() async throws {
        let deadlineGaveUp = Latch()
        let connection = HTTPSHostConnection(address: Self.address, deviceToken: { nil }, sleep: { duration in
            do {
                try await Task.sleep(for: duration)
            } catch {
                await deadlineGaveUp.open()
                throw error
            }
        })
        let caller = Task {
            try await connection.withDeadline(.seconds(30)) {
                // 回應與取消同時到：計時先因取消結束，結果才交回。
                await deadlineGaveUp.wait()
                return "stream-s1"
            }
        }

        caller.cancel()

        #expect(try await caller.value == "stream-s1")
    }

    @Test("訂閱剛送出就取消：關掉串流的請求排在訂閱之後送到主機，主機不會留著串流")
    func unsubscribeFollowsSubscribeOnTheWire() async throws {
        let socket = RecordingSocket()
        let client = HerdrClient(connection: HTTPSHostConnection(address: Self.address, deviceToken: { "token-ok" }, transport: socket))
        _ = try await client.ping()
        let reader = Task {
            for try await _ in try await client.subscribe([]) {}
        }
        await socket.subscribeStarted.wait()

        reader.cancel()

        try await waitUntil { socket.sentTypes.contains("events.unsubscribe") }
        #expect(socket.sentTypes == ["hello", "events.subscribe", "events.unsubscribe"])
    }

    @Test("Pane 終端機開啟途中取消：請主機關掉可能已開的終端機")
    func cancelledOpenClosesHostTerminal() async throws {
        let socket = ScriptedSocket(silent: ["pane.terminal.open"])
        let client = PaneTerminalClient(connection: HTTPSHostConnection(address: Self.address, deviceToken: { "token-ok" }, transport: socket))
        let opening = Task { try await client.control(target: "w1:p1", columns: 40, rows: 12) }
        await socket.started("pane.terminal.open").wait()

        opening.cancel()

        await #expect(throws: CancellationError.self) { try await opening.value }
        try await waitUntil { socket.sent.contains { $0.type == "pane.terminal.close" } }
        let open = try #require(socket.sent.first { $0.type == "pane.terminal.open" })
        #expect(socket.sent.first { $0.type == "pane.terminal.close" }?.streamID == open.requestID)
    }

    @Test("呼叫端不再讀 Pane 終端機的畫面：請主機關掉終端機")
    func abandonedTerminalClosesHostTerminal() async throws {
        let socket = ScriptedSocket()
        let client = PaneTerminalClient(connection: HTTPSHostConnection(address: Self.address, deviceToken: { "token-ok" }, transport: socket))
        let terminal = try await client.control(target: "w1:p1", columns: 40, rows: 12)
        let reading = Task { for await _ in terminal.events {} }

        reading.cancel()

        try await waitUntil { socket.sent.contains { $0.type == "pane.terminal.close" } }
        let open = try #require(socket.sent.first { $0.type == "pane.terminal.open" })
        #expect(socket.sent.first { $0.type == "pane.terminal.close" }?.streamID == open.requestID)
    }

    @Test("送出卡住超過心跳逾時：連線以 connectionLost 結束，不等到操作期限")
    func stalledSendEndsConnection() async throws {
        let socket = ScriptedSocket(stalled: ["agents.list"])
        let client = HerdrClient(connection: HTTPSHostConnection(
            address: Self.address, deviceToken: { "token-ok" }, transport: socket,
            heartbeat: HostServiceHeartbeat(interval: .seconds(3600), timeout: .milliseconds(200))))

        await #expect(throws: HostServiceError.connectionLost) { try await client.snapshot() }
    }

    @Test("終端機輸入與請求經同一個寫入者：依呼叫順序送到主機")
    func terminalInputKeepsOrderWithRequests() async throws {
        let socket = ScriptedSocket(slow: ["pane.terminal.input"])
        let connection = HTTPSHostConnection(address: Self.address, deviceToken: { "token-ok" }, transport: socket)
        let terminal = try await PaneTerminalClient(connection: connection).control(target: "w1:p1", columns: 40, rows: 12)
        let typing = Task { try await terminal.send(bytes: Data([0x61])) }
        await socket.started("pane.terminal.input").wait()

        _ = try await HerdrClient(connection: connection).snapshot()
        try await typing.value

        try await waitUntil { socket.sent.contains { $0.type == "pane.terminal.input" } }
        #expect(socket.sent.map(\.type) == ["hello", "pane.terminal.open", "pane.terminal.input", "agents.list"])
    }

    #if os(macOS) || os(Linux)
    @Test("連線中斷時系統把 ping 的完成回呼兩次：只採用第一次，app 不當掉")
    func pingCompletionCalledTwiceDoesNotCrash() async {
        await #expect(processExitsWith: .success) {
            try? await URLSessionHostServiceTransport.completion { completed in
                completed(nil)
                completed(URLError(.networkConnectionLost))
            }
        }
    }
    #endif

    private static let address = HostServiceAddress("http://127.0.0.1:1")!
}

/// 記下送到主機的訊息種類;回應握手與關掉串流。`events.subscribe` 晚一點才真的送出(排程忙)、不回應。
private final class RecordingSocket: WebSocketConnecting, WebSocketSession {
    let subscribeStarted = Latch()
    private let sent = Mutex<[String]>([])
    private let replies = Mailbox()

    var sentTypes: [String] { sent.withLock { $0 } }

    func connect(to url: URL, bearerToken: String) async throws -> any WebSocketSession { self }

    func send(_ text: String) async throws {
        let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        let type = message["type"] as? String ?? ""
        let requestID = message["request_id"] as? String ?? ""
        if type == "events.subscribe" {
            await subscribeStarted.open()
            try await Task.sleep(for: .milliseconds(200))
        }
        sent.withLock { $0.append(type) }
        switch type {
        case "hello":
            let welcome = try String(contentsOf: FakeHostService.examplesDirectory.appending(path: "server.welcome.json"), encoding: .utf8)
            await replies.put(welcome.replacingOccurrences(of: #""request_id":"r1""#, with: #""request_id":"\#(requestID)""#))
        case "events.unsubscribe":
            await replies.put(#"{"type":"events.unsubscribe.result","request_id":"\#(requestID)"}"#)
        default:
            break
        }
    }

    func receive() async throws -> WebSocketMessage {
        .text(await replies.take())
    }

    func sendPing() async throws {}

    func close() async {}
}

/// 照協定回應的腳本化主機服務：`silent` 的訊息不回應，`stalled` 的送出卡到連線關閉，`slow` 的送出晚 200 毫秒才完成。
private final class ScriptedSocket: WebSocketConnecting, WebSocketSession {
    struct Sent: Sendable {
        var type: String
        var requestID: String?
        var streamID: String?
    }

    private let silent: Set<String>
    private let stalled: Set<String>
    private let slow: Set<String>
    private let latches = Mutex<[String: Latch]>([:])
    private let recorded = Mutex<[Sent]>([])
    private let replies = Mailbox()
    private let closed = Latch()

    init(silent: Set<String> = [], stalled: Set<String> = [], slow: Set<String> = []) {
        self.silent = silent
        self.stalled = stalled
        self.slow = slow
    }

    var sent: [Sent] { recorded.withLock { $0 } }

    /// 開始送出這種訊息時打開的門。
    func started(_ type: String) -> Latch {
        latches.withLock { latches in
            if let latch = latches[type] { return latch }
            let latch = Latch()
            latches[type] = latch
            return latch
        }
    }

    func connect(to url: URL, bearerToken: String) async throws -> any WebSocketSession { self }

    func send(_ text: String) async throws {
        let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        let sent = Sent(type: message["type"] as? String ?? "", requestID: message["request_id"] as? String, streamID: message["stream_id"] as? String)
        await started(sent.type).open()
        if stalled.contains(sent.type) {
            await closed.wait()
            throw HostServiceError.connectionLost
        }
        if slow.contains(sent.type) { try await Task.sleep(for: .milliseconds(200)) }
        recorded.withLock { $0.append(sent) }
        guard !silent.contains(sent.type), let requestID = sent.requestID else { return }
        switch sent.type {
        case "hello":
            let welcome = try String(contentsOf: FakeHostService.examplesDirectory.appending(path: "server.welcome.json"), encoding: .utf8)
            await replies.put(welcome.replacingOccurrences(of: #""request_id":"r1""#, with: #""request_id":"\#(requestID)""#))
        case "agents.list":
            let agents = try String(contentsOf: FakeHostService.examplesDirectory.appending(path: "server.agents-list-result.json"), encoding: .utf8)
            let object = try JSONSerialization.jsonObject(with: Data(agents.utf8)) as? [String: Any] ?? [:]
            var replaced = object
            replaced["request_id"] = requestID
            await replies.put(String(decoding: try JSONSerialization.data(withJSONObject: replaced), as: UTF8.self))
        case "pane.terminal.open":
            await replies.put(#"{"type":"pane.terminal.open.result","request_id":"\#(requestID)","stream_id":"\#(requestID)","read_only":false}"#)
        default:
            break
        }
    }

    func receive() async throws -> WebSocketMessage {
        .text(await replies.take())
    }

    func sendPing() async throws {}

    func close() async {
        await closed.open()
    }
}

/// 一次性的門：`wait` 不理會取消，`open` 之後全部放行。
private actor Latch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// 依序交出回應;沒有時等下一個。
private actor Mailbox {
    private var queued: [String] = []
    private var waiting: [CheckedContinuation<String, Never>] = []

    func put(_ text: String) {
        if waiting.isEmpty {
            queued.append(text)
        } else {
            waiting.removeFirst().resume(returning: text)
        }
    }

    func take() async -> String {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { waiting.append($0) }
    }
}

/// 主機服務已拒絕權杖並關閉連線：app 送握手就失敗，主機關閉前送的拒絕稍後才讀到。
private final class RejectingTransport: WebSocketConnecting {
    private let dialed = Mutex(0)

    var connections: Int { dialed.withLock { $0 } }

    func connect(to url: URL, bearerToken: String) async throws -> any WebSocketSession {
        dialed.withLock { $0 += 1 }
        return RejectingSocket()
    }
}

private final class RejectingSocket: WebSocketSession {
    private let sendFailed = Latch()
    private let arriving = Mutex<[WebSocketMessage]>([
        .text(#"{"type":"error","code":"device_token_revoked","message":"revoked"}"#),
        .closed(code: HostServiceSession.unauthorizedCloseCode),
    ])

    func send(_ text: String) async throws {
        await sendFailed.open()
        throw HostServiceError.connectionLost
    }

    func receive() async throws -> WebSocketMessage {
        await sendFailed.wait()
        try await Task.sleep(for: .milliseconds(50))
        guard let next = arriving.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw HostServiceError.connectionLost }
        return next
    }

    func sendPing() async throws {}

    func close() async {}
}
