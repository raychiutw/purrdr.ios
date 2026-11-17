import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PurrdrCore

/// 以 `URLSession` 連主機服務:TLS 由系統處理，信任系統的公共 CA(Tailscale 代申請的 Let's Encrypt 憑證),不做 pinning。
///
/// 非 Apple 平台經 FoundationNetworking(libcurl)。
public struct URLSessionHostServiceTransport: WebSocketConnecting, HostServiceHTTPSending {
    private let session: URLSession
    /// 握手與一般 HTTPS 請求的逾時。
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        session = URLSession(configuration: .ephemeral)
        self.timeout = timeout
    }

    public func connect(to url: URL, bearerToken: String) async throws -> any WebSocketSession {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        // 預設上限 1 MiB;對話紀錄的視窗(300 行)可能更大。
        task.maximumMessageSize = 64 << 20
        task.resume()
        return URLSessionWebSocket(task: task)
    }

    public func post(_ url: URL, bearerToken: String?, body: Data?) async throws -> HostServiceHTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.hostServiceError(error, status: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw HostServiceError.unexpectedResponse }
        if http.statusCode == 502 { throw HostServiceError.hostServiceNotRunning }
        return HostServiceHTTPResponse(status: http.statusCode, body: data)
    }

    /// 連線層錯誤換成使用者看得懂的種類。
    static func hostServiceError(_ error: any Error, status: Int?) -> HostServiceError {
        if status == 502 { return .hostServiceNotRunning }
        guard let urlError = error as? URLError else { return .connectionLost }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return .hostNotFound
        case .cannotConnectToHost, .timedOut, .notConnectedToInternet, .secureConnectionFailed:
            return .unreachable
        default:
            return .connectionLost
        }
    }
}

/// `URLSessionWebSocketTask` 的包裝。task 本身可跨執行緒使用。
private final class URLSessionWebSocket: WebSocketSession, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw URLSessionHostServiceTransport.hostServiceError(error, status: status)
        }
    }

    func receive() async throws -> WebSocketMessage {
        do {
            switch try await task.receive() {
            case .string(let text):
                return .text(text)
            case .data(let data):
                return .text(String(decoding: data, as: UTF8.self))
            @unknown default:
                throw HostServiceError.unexpectedResponse
            }
        } catch let error as HostServiceError {
            throw error
        } catch {
            let closeCode = task.closeCode.rawValue
            if closeCode != URLSessionWebSocketTask.CloseCode.invalid.rawValue { return .closed(code: closeCode) }
            throw URLSessionHostServiceTransport.hostServiceError(error, status: status)
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private var status: Int? { (task.response as? HTTPURLResponse)?.statusCode }
}
