import Foundation
import PurrdrCore

/// 一條到主機服務的 WSS 連線：送出的請求帶請求識別碼，回應依識別碼交回呼叫端(可同時有多個請求)。
///
/// 連線結束(斷線、close frame、權杖被拒)後不再使用;所有等待中的請求以結束原因失敗，不重送。
actor HostServiceSession {
    /// 這條連線用的裝置權杖(被拒時記下是哪一個)。
    let deviceToken: String
    private let socket: any WebSocketSession
    private var pending: [String: CheckedContinuation<HostServiceProtocol.ServerMessage, any Error>] = [:]
    private var closeWaiters: [UUID: CheckedContinuation<any Error, Never>] = [:]
    /// 開著的串流，以串流識別碼為 key。
    private var streams: [String: AsyncStream<HostServiceProtocol.ServerMessage>.Continuation] = [:]
    private var ending: (any Error)?
    private var nextRequestNumber = 0
    private var reader: Task<Void, Never>?

    init(socket: any WebSocketSession, deviceToken: String) {
        self.socket = socket
        self.deviceToken = deviceToken
    }

    var isOpen: Bool { ending == nil }

    func start() {
        reader = Task { await self.readUntilClosed() }
    }

    /// 送出一個請求(`make` 拿到請求識別碼),等同一個識別碼的回應。外層取消時丟 `CancellationError`。
    func request(_ make: @Sendable (String) -> HostServiceProtocol.ClientMessage) async throws -> HostServiceProtocol.ServerMessage {
        try await request(make, stream: nil)
    }

    /// 開一個串流：串流識別碼就是請求識別碼。回應之後帶這個串流識別碼的訊息依序交給 `messages`;
    /// 串流結束(`pane.terminal.closed`)或連線結束時 `messages` 結束。開啟失敗時 `messages` 不會有訊息。
    func openStream(
        _ make: @Sendable (String) -> HostServiceProtocol.ClientMessage
    ) async throws -> (reply: HostServiceProtocol.ServerMessage, messages: AsyncStream<HostServiceProtocol.ServerMessage>) {
        let (messages, continuation) = AsyncStream<HostServiceProtocol.ServerMessage>.makeStream()
        let reply = try await request(make, stream: continuation)
        if case .errorMessage(let error) = reply, let requestID = error.requestId {
            streams.removeValue(forKey: requestID)?.finish()
        }
        return (reply, messages)
    }

    /// 送出沒有回應的訊息(串流上的輸入)。連線已結束時丟結束原因。
    func post(_ message: HostServiceProtocol.ClientMessage) async throws {
        if let ending { throw ending }
        let text = try String(decoding: JSONEncoder().encode(message), as: UTF8.self)
        do {
            try await socket.send(text)
        } catch {
            let failure = error as? HostServiceError ?? .connectionLost
            end(with: failure)
            throw failure
        }
    }

    /// 串流先登記再送出請求：回應之後立刻到的串流訊息不會漏掉。
    private func request(
        _ make: @Sendable (String) -> HostServiceProtocol.ClientMessage,
        stream: AsyncStream<HostServiceProtocol.ServerMessage>.Continuation?
    ) async throws -> HostServiceProtocol.ServerMessage {
        if let ending {
            stream?.finish()
            throw ending
        }
        nextRequestNumber += 1
        let requestID = "r\(nextRequestNumber)"
        let text = try String(decoding: JSONEncoder().encode(make(requestID)), as: UTF8.self)
        if let stream { streams[requestID] = stream }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                pending[requestID] = continuation
                Task { await self.send(text, for: requestID) }
            }
        } onCancel: {
            Task { await self.abandon(requestID) }
        }
    }

    /// 等到連線結束，回傳結束原因。外層取消時回 `CancellationError`。
    func waitUntilClosed() async -> any Error {
        if let ending { return ending }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let ending { return continuation.resume(returning: ending) }
                guard !Task.isCancelled else { return continuation.resume(returning: CancellationError()) }
                closeWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.stopWaiting(waiterID) }
        }
    }

    func close() async {
        end(with: HostServiceError.connectionLost)
        await socket.close()
    }

    // MARK: - 內部

    private func send(_ text: String, for requestID: String) async {
        do {
            try await socket.send(text)
        } catch {
            end(with: error as? HostServiceError ?? .connectionLost)
        }
    }

    private func abandon(_ requestID: String) {
        pending.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
        streams.removeValue(forKey: requestID)?.finish()
    }

    private func stopWaiting(_ waiterID: UUID) {
        closeWaiters.removeValue(forKey: waiterID)?.resume(returning: CancellationError())
    }

    private func readUntilClosed() async {
        while ending == nil {
            let message: WebSocketMessage
            do {
                message = try await socket.receive()
            } catch {
                end(with: error as? HostServiceError ?? .connectionLost)
                break
            }
            switch message {
            case .closed(let code):
                end(with: code == Self.unauthorizedCloseCode ? HostServiceError.deviceTokenInvalid : HostServiceError.connectionLost)
            case .text(let text):
                deliver(text)
            }
        }
        await socket.close()
    }

    private func deliver(_ text: String) {
        let data = Data(text.utf8)
        guard let message = try? JSONDecoder().decode(HostServiceProtocol.ServerMessage.self, from: data) else {
            // 讀不懂的回應：有請求識別碼就讓那個請求失敗，其他略過(之後版本的訊息)。
            if let requestID = (try? JSONDecoder().decode(RequestIDOnly.self, from: data))?.requestId {
                pending.removeValue(forKey: requestID)?.resume(throwing: HostServiceError.unexpectedResponse)
            }
            return
        }
        if let streamID = message.streamID {
            streams[streamID]?.yield(message)
            if case .paneTerminalClosed = message { streams.removeValue(forKey: streamID)?.finish() }
        } else if let requestID = message.requestID {
            pending.removeValue(forKey: requestID)?.resume(returning: message)
        } else if case .errorMessage(let error) = message, let rejection = HostServiceError(tokenRejection: error.code) {
            // 權杖無效或已撤銷：主機服務接著會以 4401 關閉。
            end(with: rejection)
        }
    }

    /// 連線結束：等待中的請求與等待者都以 `error` 結束。
    private func end(with error: any Error) {
        guard ending == nil else { return }
        ending = error
        let requests = pending
        pending = [:]
        for continuation in requests.values { continuation.resume(throwing: error) }
        let waiters = closeWaiters
        closeWaiters = [:]
        for continuation in waiters.values { continuation.resume(returning: error) }
        let openStreams = streams
        streams = [:]
        for continuation in openStreams.values { continuation.finish() }
    }

    /// 權杖無效或已撤銷時主機服務關閉連線的 close code。
    static let unauthorizedCloseCode = 4401

    private struct RequestIDOnly: Decodable {
        var requestId: String?

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol.ServerMessage {
    /// 回應帶回的請求識別碼(沒有對應請求的錯誤是 `nil`)。
    var requestID: String? {
        switch self {
        case .welcome(let message): message.requestId
        case .agentsListResult(let message): message.requestId
        case .paneSendKeysResult(let message): message.requestId
        case .paneSendTextResult(let message): message.requestId
        case .agentPromptResult(let message): message.requestId
        case .paneTerminalOpenResult(let message): message.requestId
        case .paneTerminalFrame, .paneTerminalClosed: nil
        case .errorMessage(let message): message.requestId
        }
    }

    /// 串流訊息的串流識別碼(其他訊息是 `nil`)。
    var streamID: String? {
        switch self {
        case .paneTerminalFrame(let message): message.streamId
        case .paneTerminalClosed(let message): message.streamId
        default: nil
        }
    }
}

extension HostServiceError {
    /// 權杖被拒的錯誤碼;其他碼回 `nil`。
    init?(tokenRejection code: HostServiceProtocol.ErrorCode) {
        switch code {
        case .deviceTokenInvalid: self = .deviceTokenInvalid
        case .deviceTokenRevoked: self = .deviceTokenRevoked
        default: return nil
        }
    }
}
