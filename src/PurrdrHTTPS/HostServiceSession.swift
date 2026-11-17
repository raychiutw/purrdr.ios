import Foundation
import PurrdrCore

/// 一條到主機服務的 WSS 連線：送出的請求帶請求識別碼，回應依識別碼交回呼叫端(可同時有多個請求);
/// 串流的訊息依串流識別碼交給 `openStream` 的串流。
///
/// 連線結束(斷線、close frame、權杖被拒、心跳逾時)後不再使用;所有等待中的請求與串流以結束原因失敗，不重送。
actor HostServiceSession {
    /// 這條連線用的裝置權杖(被拒時記下是哪一個)。
    let deviceToken: String
    private let socket: any WebSocketSession
    private var pending: [String: CheckedContinuation<HostServiceProtocol.ServerMessage, any Error>] = [:]
    private var streams: [String: AsyncThrowingStream<HostServiceProtocol.ServerMessage, any Error>.Continuation] = [:]
    private var closeWaiters: [UUID: CheckedContinuation<any Error, Never>] = [:]
    private var ending: (any Error)?
    private var nextRequestNumber = 0
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?

    init(socket: any WebSocketSession, deviceToken: String) {
        self.socket = socket
        self.deviceToken = deviceToken
    }

    var isOpen: Bool { ending == nil }

    func start(heartbeat settings: HostServiceHeartbeat, sleep: @escaping Sleep) {
        reader = Task { await self.readUntilClosed() }
        heartbeat = Task { await self.beat(settings, sleep: sleep) }
    }

    /// 開始收某條串流的訊息(在送出開串流的請求之前呼叫，才不會漏掉緊接著回應的訊息)。
    /// 主機端結束串流(`events.ended`)時先交出那則訊息再結束;連線結束時以結束原因失敗。
    func openStream(_ streamID: String) -> AsyncThrowingStream<HostServiceProtocol.ServerMessage, any Error> {
        let (messages, continuation) = AsyncThrowingStream<HostServiceProtocol.ServerMessage, any Error>.makeStream()
        if let ending {
            continuation.finish(throwing: ending)
        } else {
            streams[streamID] = continuation
        }
        return messages
    }

    /// 不再收這條串流;回傳它原本是否還開著(主機端已結束或連線已斷的回 `false`)。
    func closeStream(_ streamID: String) -> Bool {
        guard let continuation = streams.removeValue(forKey: streamID) else { return false }
        continuation.finish()
        return true
    }

    /// 送出一個請求(`make` 拿到請求識別碼),等同一個識別碼的回應。外層取消時丟 `CancellationError`。
    func request(_ make: @Sendable (String) -> HostServiceProtocol.ClientMessage) async throws -> HostServiceProtocol.ServerMessage {
        if let ending { throw ending }
        nextRequestNumber += 1
        let requestID = "r\(nextRequestNumber)"
        let text = try String(decoding: JSONEncoder().encode(make(requestID)), as: UTF8.self)
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

    /// 每 `interval` 送一次 ping;`timeout` 內沒有 pong 就當作斷線(網路換了路徑、主機睡著)。
    private func beat(_ settings: HostServiceHeartbeat, sleep: @escaping Sleep) async {
        while ending == nil {
            do {
                try await sleep(settings.interval)
            } catch {
                return
            }
            guard ending == nil else { return }
            guard await Self.pong(from: socket, within: settings.timeout, sleep: sleep) else {
                end(with: HostServiceError.connectionLost)
                await socket.close()
                return
            }
        }
    }

    /// ping 與計時賽跑;不等輸的一方結束(卡住的 ping 在連線關閉時才返回)。
    private static func pong(from socket: any WebSocketSession, within timeout: Duration, sleep: @escaping Sleep) async -> Bool {
        let (outcomes, continuation) = AsyncStream<Bool>.makeStream()
        let ping = Task { continuation.yield((try? await socket.sendPing()) != nil) }
        let timer = Task {
            try? await sleep(timeout)
            continuation.yield(false)
        }
        var iterator = outcomes.makeAsyncIterator()
        let answered = await iterator.next() ?? false
        ping.cancel()
        timer.cancel()
        continuation.finish()
        return answered
    }

    private func send(_ text: String, for requestID: String) async {
        do {
            try await socket.send(text)
        } catch {
            end(with: error as? HostServiceError ?? .connectionLost)
        }
    }

    private func abandon(_ requestID: String) {
        pending.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
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
        switch message {
        case .subscribedEvent(let event):
            streams[event.streamId]?.yield(message)
        case .eventsEnded(let ended):
            let stream = streams.removeValue(forKey: ended.streamId)
            stream?.yield(message)
            stream?.finish()
        case .errorMessage(let error) where error.requestId == nil:
            // 權杖無效或已撤銷：主機服務接著會以 4401 關閉。
            if let rejection = HostServiceError(tokenRejection: error.code) { end(with: rejection) }
        default:
            if let requestID = message.requestID { pending.removeValue(forKey: requestID)?.resume(returning: message) }
        }
    }

    /// 連線結束：等待中的請求、串流與等待者都以 `error` 結束。
    private func end(with error: any Error) {
        guard ending == nil else { return }
        ending = error
        heartbeat?.cancel()
        let requests = pending
        pending = [:]
        for continuation in requests.values { continuation.resume(throwing: error) }
        let openStreams = streams
        streams = [:]
        for continuation in openStreams.values { continuation.finish(throwing: error) }
        let waiters = closeWaiters
        closeWaiters = [:]
        for continuation in waiters.values { continuation.resume(returning: error) }
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
        case .eventsSubscribeResult(let message): message.requestId
        case .eventsUnsubscribeResult(let message): message.requestId
        case .errorMessage(let message): message.requestId
        case .subscribedEvent, .eventsEnded: nil
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
