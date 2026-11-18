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
