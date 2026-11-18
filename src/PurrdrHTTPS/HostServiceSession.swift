import Foundation
import PurrdrCore

/// 一條到主機服務的 WSS 連線：送出的請求帶請求識別碼，回應依識別碼交回呼叫端(可同時有多個請求);
/// 帶串流識別碼的推送都經同一張登記表(`streams`):事件與 Pane 終端機依序交給呼叫端的串流，
/// 對話紀錄的推送暫存到 `takeBufferedMessages` 取走。
///
/// 串流識別碼：app 指定的(事件、對話紀錄)由 `makeStreamID` 配發 `s<n>`;Pane 終端機是開啟請求的請求識別碼 `r<n>`。
///
/// 連線結束(斷線、close frame、權杖被拒、心跳逾時)後不再使用;所有等待中的請求與串流以結束原因失敗，不重送。
actor HostServiceSession {
    /// 這條連線用的裝置權杖(被拒時記下是哪一個)。
    let deviceToken: String
    private let socket: any WebSocketSession
    private var pending: [String: CheckedContinuation<HostServiceProtocol.ServerMessage, any Error>] = [:]
    private var closeWaiters: [UUID: CheckedContinuation<any Error, Never>] = [:]
    /// 開著的串流(串流識別碼 → 收訊息的方式)。
    private var streams: [String: OpenStream] = [:]
    private var ending: (any Error)?
    private var nextRequestNumber = 0
    private var nextStreamNumber = 0
    private var reader: Task<Void, Never>?
    /// 待送的訊息，由同一個寫入者依呼叫順序送出(例如關掉串流不會比開串流先到主機)。
    private let outgoing: AsyncStream<String>
    private let outgoingQueue: AsyncStream<String>.Continuation
    private var heartbeat: Task<Void, Never>?
    private var sleep: Sleep = Sleeping.task

    typealias Messages = AsyncThrowingStream<HostServiceProtocol.ServerMessage, any Error>

    /// 推送訊息怎麼交給呼叫端。
    private enum OpenStream {
        /// 依序交給串流;主機端結束串流或連線結束時結束。
        case delivering(Messages.Continuation)
        /// 暫存，呼叫端取走;積壓太多時丟掉整個串流。
        case buffering([HostServiceProtocol.ServerMessage])
    }

    init(socket: any WebSocketSession, deviceToken: String) {
        self.socket = socket
        self.deviceToken = deviceToken
        (outgoing, outgoingQueue) = AsyncStream<String>.makeStream()
    }

    var isOpen: Bool { ending == nil }

    func start(heartbeat settings: HostServiceHeartbeat, sleep: @escaping Sleep) {
        self.sleep = sleep
        reader = Task { await self.readUntilClosed() }
        Task { await self.writeInOrder() }
        heartbeat = Task { await self.beat(settings, sleep: sleep) }
    }

    /// 配發 app 指定的串流識別碼(這條連線內不重複)。
    func makeStreamID() -> String {
        nextStreamNumber += 1
        return "s\(nextStreamNumber)"
    }

    /// 開始依序收這個串流的推送(在送出開始串流的請求之前呼叫，才不會漏掉緊接著回應的推送)。
    /// 主機端結束串流時先交出那則訊息再結束;連線結束時以結束原因失敗。
    func openStream(_ streamID: String) -> Messages {
        let (messages, continuation) = Messages.makeStream()
        if let ending {
            continuation.finish(throwing: ending)
        } else {
            streams[streamID] = .delivering(continuation)
        }
        return messages
    }

    /// 開始暫存這個串流的推送，之後以 `takeBufferedMessages` 取走。
    func openBufferedStream(_ streamID: String) {
        streams[streamID] = .buffering([])
    }

    /// 取走這個串流目前暫存的推送;串流沒開、已關或積壓太多被丟掉時是 `nil`。
    func takeBufferedMessages(_ streamID: String) -> [HostServiceProtocol.ServerMessage]? {
        guard case .buffering(let messages) = streams[streamID] else { return nil }
        streams[streamID] = .buffering([])
        return messages
    }

    /// 不再收這個串流;回傳它原本是否還開著(主機端已結束或連線已斷的回 `false`)。
    @discardableResult
    func closeStream(_ streamID: String) -> Bool {
        guard let stream = streams.removeValue(forKey: streamID) else { return false }
        if case .delivering(let continuation) = stream { continuation.finish() }
        return true
    }

    /// 送出一個請求(`make` 拿到請求識別碼),等同一個識別碼的回應。外層取消時丟 `CancellationError`。
    func request(_ make: @Sendable (String) -> HostServiceProtocol.ClientMessage) async throws -> HostServiceProtocol.ServerMessage {
        try await request(make, stream: nil)
    }

    /// 送出開啟串流的請求，串流識別碼是這個請求識別碼(Pane 終端機)。回應之後帶這個串流識別碼的訊息依序交給
    /// `messages`;主機端結束串流或連線結束時 `messages` 結束。開啟失敗時 `messages` 不會有訊息。
    func requestStream(_ make: @Sendable (String) -> HostServiceProtocol.ClientMessage) async throws -> StreamReply {
        let (messages, continuation) = Messages.makeStream()
        let reply = try await request(make, stream: continuation)
        if case .errorMessage(let error) = reply, let requestID = error.requestId { closeStream(requestID) }
        return StreamReply(reply: reply, messages: messages)
    }

    /// `requestStream` 的回應與之後的串流訊息。
    struct StreamReply {
        var reply: HostServiceProtocol.ServerMessage
        var messages: Messages
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
        stream: Messages.Continuation?
    ) async throws -> HostServiceProtocol.ServerMessage {
        if let ending {
            stream?.finish(throwing: ending)
            throw ending
        }
        nextRequestNumber += 1
        let requestID = "r\(nextRequestNumber)"
        let text = try String(decoding: JSONEncoder().encode(make(requestID)), as: UTF8.self)
        if let stream { streams[requestID] = .delivering(stream) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                pending[requestID] = continuation
                outgoingQueue.yield(text)
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

    /// 一個暫存串流最多積壓的推送數;超過就丟掉整個串流(呼叫端重新開始)。
    static let maximumPendingStreamMessages = 256

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

    private func writeInOrder() async {
        for await text in outgoing {
            do {
                try await socket.send(text)
            } catch {
                // 主機關閉前送的原因(例如權杖被拒)可能還沒讀到：讀取端先結束就以它的原因為準。
                await waitForReader(within: Self.sendFailureGrace)
                end(with: error as? HostServiceError ?? .connectionLost)
                return
            }
        }
    }

    /// 送出失敗後等讀取端讀完已到的訊息的上限。
    static let sendFailureGrace: Duration = .seconds(1)

    /// 等讀取端結束(連線結束)或 `limit` 到，先到的為準。
    private func waitForReader(within limit: Duration) async {
        let (outcomes, continuation) = AsyncStream<Void>.makeStream()
        let readerEnded = Task { [reader] in
            await reader?.value
            continuation.yield()
        }
        let timer = Task { [sleep] in
            try? await sleep(limit)
            continuation.yield()
        }
        var iterator = outcomes.makeAsyncIterator()
        _ = await iterator.next()
        readerEnded.cancel()
        timer.cancel()
        continuation.finish()
    }

    private func abandon(_ requestID: String) {
        pending.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
        closeStream(requestID)
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
        if let streamID = message.streamID { return push(message, to: streamID) }
        switch message {
        case .errorMessage(let error) where error.requestId == nil:
            // 權杖無效或已撤銷：主機服務接著會以 4401 關閉。
            if let rejection = HostServiceError(tokenRejection: error.code) { end(with: rejection) }
        default:
            if let requestID = message.requestID { pending.removeValue(forKey: requestID)?.resume(returning: message) }
        }
    }

    private func push(_ message: HostServiceProtocol.ServerMessage, to streamID: String) {
        switch streams[streamID] {
        case .delivering(let continuation):
            continuation.yield(message)
            if message.endsStream { closeStream(streamID) }
        case .buffering(var messages):
            messages.append(message)
            streams[streamID] = messages.count > Self.maximumPendingStreamMessages ? nil : .buffering(messages)
        case nil:
            break
        }
    }

    /// 連線結束：等待中的請求、串流與等待者都以 `error` 結束。
    private func end(with error: any Error) {
        guard ending == nil else { return }
        ending = error
        heartbeat?.cancel()
        outgoingQueue.finish()
        let requests = pending
        pending = [:]
        for continuation in requests.values { continuation.resume(throwing: error) }
        let openStreams = streams
        streams = [:]
        for case .delivering(let continuation) in openStreams.values { continuation.finish(throwing: error) }
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
    /// 串流上的推送帶的串流識別碼(回應是 `nil`)。
    var streamID: String? {
        switch self {
        case .subscribedEvent(let message): message.streamId
        case .eventsEnded(let message): message.streamId
        case .transcriptUpdate(let message): message.streamId
        case .paneTerminalFrame(let message): message.streamId
        case .paneTerminalClosed(let message): message.streamId
        case .welcome, .agentsListResult, .paneSendKeysResult, .transcriptLocateResult, .transcriptWindowResult, .transcriptFollowResult,
             .transcriptUnfollowResult, .paneSendTextResult, .agentPromptResult, .eventsSubscribeResult, .eventsUnsubscribeResult,
             .paneTerminalOpenResult, .errorMessage: nil
        }
    }

    /// 主機端結束串流的訊息(交出這則後串流結束)。
    var endsStream: Bool {
        switch self {
        case .eventsEnded, .paneTerminalClosed: true
        default: false
        }
    }

    /// 回應帶回的請求識別碼(沒有對應請求的錯誤是 `nil`)。
    var requestID: String? {
        switch self {
        case .welcome(let message): message.requestId
        case .agentsListResult(let message): message.requestId
        case .paneSendKeysResult(let message): message.requestId
        case .transcriptLocateResult(let message): message.requestId
        case .transcriptWindowResult(let message): message.requestId
        case .transcriptFollowResult(let message): message.requestId
        case .transcriptUnfollowResult(let message): message.requestId
        case .paneSendTextResult(let message): message.requestId
        case .agentPromptResult(let message): message.requestId
        case .eventsSubscribeResult(let message): message.requestId
        case .eventsUnsubscribeResult(let message): message.requestId
        case .paneTerminalOpenResult(let message): message.requestId
        case .errorMessage(let message): message.requestId
        case .transcriptUpdate, .subscribedEvent, .eventsEnded, .paneTerminalFrame, .paneTerminalClosed: nil
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
