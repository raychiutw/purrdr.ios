import Foundation
import PurrdrCore
@testable import PurrdrHTTPS
import Synchronization
import Testing

/// WebSocket 計量的記錄時機(#353):`send` 的完成回呼可能比主機的回應更晚才回來(負載高時),
/// 所以送出的位元組在交給傳輸層的當下就要算進去,不能等 `send` 返回——否則「回應都收到了、送出的位元組還沒算」,
/// 完整 `swift test` 負載下 `TrafficMeteringConnectionTests.httpsWebSocket` 偶發少算最後一則。
@Suite("流量計量:WebSocket 記錄時機")
struct MeteredWebSocketOrderingTests {
    /// `send` 交給傳輸層後一直不返回,直到測試放行(模擬完成回呼比回應晚)。
    private final class SlowSendSession: WebSocketSession {
        private let entered = Mutex<CheckedContinuation<Void, Never>?>(nil)
        private let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
        private let didEnter = Mutex(false)

        func send(_ text: String) async throws {
            didEnter.withLock { $0 = true }
            await withCheckedContinuation { continuation in release.withLock { $0 = continuation } }
        }

        func waitUntilSending() async {
            while !didEnter.withLock({ $0 }) { await Task.yield() }
            while release.withLock({ $0 }) == nil { await Task.yield() }
        }

        func releaseSend() { release.withLock { $0 }?.resume() }

        func receive() async throws -> WebSocketMessage { .closed(code: nil) }
        func sendPing() async throws {}
        func close() async {}
    }

    private struct Connector: WebSocketConnecting {
        let session: SlowSendSession
        func connect(to url: URL, bearerToken: String) async throws -> any WebSocketSession { session }
    }

    @Test("送出的位元組在交給傳輸層時就算進去,不等 send 返回")
    func sentBytesAreCountedBeforeSendReturns() async throws {
        let meter = TrafficMeter(store: InMemoryTrafficStore(), network: .wifi)
        let base = SlowSendSession()
        let transport = MeteredWebSocketTransport(base: Connector(session: base), sink: TrafficSink(meter.recorder(for: "h")))
        let session = try await transport.connect(to: URL(string: "wss://example.test/v1/ws")!, bearerToken: "t")

        let sending = Task { try await session.send("你好 hello") }
        await base.waitUntilSending()

        #expect(meter.today()["h"]?[.wifi]?.sent == "你好 hello".utf8.count, "send 還沒返回時,位元組就該算進去")
        base.releaseSend()
        try await sending.value
        #expect(meter.today()["h"]?[.wifi]?.sent == "你好 hello".utf8.count, "不重複計算")
    }
}
