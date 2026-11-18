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

    private static let address = HostServiceAddress("http://127.0.0.1:1")!
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
