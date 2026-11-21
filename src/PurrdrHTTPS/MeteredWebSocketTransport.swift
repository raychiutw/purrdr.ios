import Foundation
import PurrdrCore

/// 在 WebSocket 傳輸外面計量(#353):每個文字訊息的 UTF-8 位元組算一次(不含 WebSocket 與 TLS 的框架開銷、ping)。
struct MeteredWebSocketTransport: WebSocketConnecting {
    let base: any WebSocketConnecting
    let sink: TrafficSink

    func connect(to url: URL, bearerToken: String) async throws -> any WebSocketSession {
        MeteredWebSocketSession(base: try await base.connect(to: url, bearerToken: bearerToken), sink: sink)
    }
}

private struct MeteredWebSocketSession: WebSocketSession {
    let base: any WebSocketSession
    let sink: TrafficSink

    func send(_ text: String) async throws {
        try await base.send(text)
        sink.record(.sent, text.utf8.count)
    }

    func receive() async throws -> WebSocketMessage {
        let message = try await base.receive()
        if case .text(let text) = message { sink.record(.received, text.utf8.count) }
        return message
    }

    func sendPing() async throws { try await base.sendPing() }
    func close() async { await base.close() }
}
