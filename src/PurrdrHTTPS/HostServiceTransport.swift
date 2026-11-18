import Foundation
import PurrdrCore

/// 開一條到主機服務的 WebSocket(WSS)。正式實作 `URLSessionHostServiceTransport`(系統 TLS、公共 CA,不 pin)。
public protocol WebSocketConnecting: Sendable {
    /// 帶 `Authorization: Bearer <裝置權杖>` 連到 `url`。握手失敗可能要到第一次收送才知道。
    func connect(to url: URL, bearerToken: String) async throws -> any WebSocketSession
}

/// 一條 WebSocket。只用文字訊息(協定是 JSON)。
public protocol WebSocketSession: Sendable {
    func send(_ text: String) async throws
    /// 下一個訊息;主機服務關閉連線時回 `.closed`,連線層失敗丟 `HostServiceError`。
    func receive() async throws -> WebSocketMessage
    /// 送 WebSocket ping,收到 pong 才返回(心跳)。
    func sendPing() async throws
    func close() async
}

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    /// 主機服務送了 close frame(`code` 讀不到時是 `nil`)。
    case closed(code: Int?)
}

/// 連線配對與撤銷用的 HTTPS 請求(`POST`,JSON 本文)。
public protocol HostServiceHTTPSending: Sendable {
    func post(_ url: URL, bearerToken: String?, body: Data?) async throws -> HostServiceHTTPResponse
}

public struct HostServiceHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}
