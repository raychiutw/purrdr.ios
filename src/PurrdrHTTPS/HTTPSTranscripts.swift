import Foundation
import PurrdrCore

/// HTTPS 的對話紀錄(#59):定位與視窗是單次請求;尾端由主機服務推送(`transcript.follow`),
/// `tail` 從推送累積的行回答，不必每次輪詢都經網路。回傳的格式與 SSH 的腳本輸出相同，`TranscriptReader` 照原樣解析。
extension HTTPSHostConnection {
    func transcript(_ request: TranscriptRequest) async throws -> Data {
        switch request {
        case .locate(let location):
            return try await withDeadline(HostCommandDeadline.standard) {
                try await self.locate(location.sessionReference, header: location.locator.readsHeader)
            }
        case .window(let path, let end, let lines, _, let maxBytes):
            return try await withDeadline(HostCommandDeadline.maximumRead) {
                try await self.window(path: path, end: end, lines: lines, maxBytes: maxBytes)
            }
        case .tail(let path, let cursor, let limit), .catchUp(let path, let cursor, let limit):
            // 主機服務(#173 起)落後超過上限時從游標分段送出，與 SSH 的分段接著讀相同;#173 之前的主機服務落後超過上限
            // 就以 too_far_behind 結束、只回大小，`TranscriptReader.catchUp` 改回報落後太多(讀新視窗)。
            // 行從推送累積的緩衝回答，不必依上限放寬期限。
            return try await withDeadline(HostCommandDeadline.standard) {
                try await self.tail(path: path, from: cursor, limit: limit).data
            }
        case .previews(let marker, let requests):
            return try await previews(marker: marker, requests: requests)
        case .findSubagent(let sessionFolder, let callID):
            return try await findSubagent(sessionFolder: sessionFolder, callID: callID)
        case .readWorkflow(let sessionFolder, let runID, let knownChecksum):
            return try await workflowOutput(sessionFolder: sessionFolder, runID: runID, knownChecksum: knownChecksum)
        case .delegationLines(let path, let callID, let agentID, let knownChecksum):
            return try await delegationOutput(path: path, callID: callID, agentID: agentID, knownChecksum: knownChecksum)
        }
    }

    /// 「路徑、大小、header 各一行」。
    private func locate(_ session: HostServiceProtocol.SessionReference, header: Bool) async throws -> Data {
        let result = try await locateResult(session, header: header)
        return Data(([result.path, String(result.size)] + (result.header ?? [])).map { $0 + "\n" }.joined().utf8)
    }

    func locateResult(_ session: HostServiceProtocol.SessionReference, header: Bool) async throws -> HostServiceProtocol.TranscriptLocateResult {
        let reply = try await send { .transcriptLocate(.init(requestId: $0, session: session, header: header)) }
        guard case .transcriptLocateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return result
    }

    /// 「起點 終點」一行，再接範圍內的行。
    /// `maxBytes` 大於 0 且主機服務有 `max_bytes`(0.11.0 起)時帶上，傳輸量有上限(#356);更舊的主機服務只限行數。
    private func window(path: String, end: Int, lines: Int, maxBytes: Int) async throws -> Data {
        let installed = maxBytes > 0 ? ((try? await hostServiceVersion()) ?? nil) : nil
        let limit: Int? = HostServiceFeature.transcriptWindowMaxBytes.isAvailable(onHostServiceVersion: installed) ? maxBytes : nil
        let reply = try await send { .transcriptWindow(.init(requestId: $0, path: path, end: end, lines: lines, maxBytes: limit)) }
        guard case .transcriptWindowResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return Data("\(result.start) \(result.end)\n".utf8) + Self.recordLines(result.records)
    }

    /// 「大小」一行，再接游標之後的完整行。追蹤中且游標在已收到的範圍內時不經網路;否則(第一次、換了游標、
    /// 重新連線、主機結束追蹤之後)開始新的追蹤。
    func tail(path: String, from cursor: Int, limit: Int) async throws -> TailAnswer {
        if var follow = transcriptFollows.removeValue(forKey: path) {
            if await follow.session.isOpen, let pushed = await follow.session.takeBufferedMessages(follow.streamID) {
                follow.apply(pushed)
                if follow.ended != nil || follow.canAnswer(from: cursor) {
                    return try await answer(follow, path: path, cursor: cursor)
                }
            }
            await stopFollowing(follow)
        }
        let session = try await liveSession()
        let streamID = await session.makeStreamID()
        await session.openBufferedStream(streamID)
        let reply: HostServiceProtocol.ServerMessage
        do {
            reply = try await send(on: session) {
                .transcriptFollow(.init(requestId: $0, streamId: streamID, path: path, from: cursor, limit: limit))
            }
        } catch {
            await session.closeStream(streamID)
            throw error
        }
        guard case .transcriptFollowResult(let result) = reply else {
            await session.closeStream(streamID)
            throw HostServiceError.unexpectedResponse
        }
        var follow = TranscriptFollow(session: session, streamID: streamID, cursor: cursor)
        follow.apply(size: result.size, start: result.start, records: result.records, ended: result.ended)
        if let pushed = await session.takeBufferedMessages(streamID) { follow.apply(pushed) }
        return try await answer(follow, path: path, cursor: cursor)
    }

    /// 回答這次讀取;主機已結束追蹤就丟掉這個追蹤(下次重新開始),否則留著並丟掉游標之前的行。
    private func answer(_ follow: TranscriptFollow, path: String, cursor: Int) async throws -> TailAnswer {
        let output = follow.output(from: cursor)
        guard let ended = follow.ended else {
            var kept = follow
            kept.discard(before: cursor)
            // 同一個路徑同時被兩個讀取開了追蹤：只留最新的，另一個請主機停止。
            if let replaced = transcriptFollows.updateValue(kept, forKey: path), replaced.streamID != kept.streamID {
                await stopFollowing(replaced)
            }
            return output
        }
        await follow.session.closeStream(follow.streamID)
        switch ended {
        case .absent: throw TranscriptReadError.absent
        case .unreadable: throw TranscriptReadError.unreadable
        case .replaced: throw TranscriptReadError.replaced(size: follow.size)
        case .shrank, .tooFarBehind: return output
        }
    }

    /// 不再追蹤：主機還在追蹤就請它停止(不等回應;呼叫端可能正被取消)。
    func stopFollowing(_ follow: TranscriptFollow) async {
        await follow.session.closeStream(follow.streamID)
        guard follow.ended == nil, await follow.session.isOpen else { return }
        let session = follow.session
        let streamID = follow.streamID
        Task { _ = try? await session.request { .transcriptUnfollow(.init(requestId: $0, streamId: streamID)) } }
    }

    // MARK: - 追蹤串流

    /// 追蹤尾端(#165):主機服務推送的 `transcript.update` 直接轉成事件，不看 `pace`。同一個路徑先前的追蹤
    /// (一次性讀取開的或另一個串流)請主機停止。呼叫端不再讀或 `stopFollowingTranscript(path:)` 時送 `transcript.unfollow`。
    public func followTranscript(path: String, from cursor: Int, pace: TranscriptFollowPace) async -> AsyncThrowingStream<TranscriptFollowEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream<TranscriptFollowEvent, any Error>.makeStream()
        if let follow = transcriptFollows.removeValue(forKey: path) { await stopFollowing(follow) }
        transcriptStreams.removeValue(forKey: path)?.continuation.finish()
        let stream = TranscriptStream(continuation: continuation)
        transcriptStreams[path] = stream
        let forwarding = Task { await self.forwardTranscript(path: path, from: cursor, to: continuation) }
        continuation.onTermination = { _ in
            forwarding.cancel()
            Task { await self.forgetTranscriptStream(stream, path: path) }
        }
        return events
    }

    private func forwardTranscript(
        path: String, from cursor: Int, to continuation: AsyncThrowingStream<TranscriptFollowEvent, any Error>.Continuation
    ) async {
        var opened: (session: HostServiceSession, streamID: String)?
        do {
            let session = try await liveSession()
            let streamID = await session.makeStreamID()
            let messages = await session.openStream(streamID)
            opened = (session, streamID)
            // 落後超過上限時主機服務分段送出(#173,每則最多 limit bytes、超大單行截短);舊版主機服務改以 too_far_behind 結束。
            let reply = try await withDeadline(HostCommandDeadline.standard) {
                try await self.send(on: session) {
                    .transcriptFollow(.init(requestId: $0, streamId: streamID, path: path, from: cursor, limit: TranscriptReader.catchUpLimit))
                }
            }
            guard case .transcriptFollowResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
            var pushed = PushedTranscript(position: cursor)
            var isEnded = try pushed.forward(size: result.size, start: result.start, records: result.records, ended: result.ended, to: continuation)
            if !isEnded {
                for try await case .transcriptUpdate(let update) in messages {
                    isEnded = try pushed.forward(size: update.size, start: update.start, records: update.records, ended: update.ended, to: continuation)
                    if isEnded { break }
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
        // 主機還在推就請它停止(主機已結束或連線已斷時串流已不在登記表)。不等回應：呼叫端可能正被取消。
        if let opened, await opened.session.closeStream(opened.streamID) {
            let (session, streamID) = opened
            Task { _ = try? await session.request { .transcriptUnfollow(.init(requestId: $0, streamId: streamID)) } }
        }
    }

    private func forgetTranscriptStream(_ stream: TranscriptStream, path: String) {
        if transcriptStreams[path]?.id == stream.id { transcriptStreams[path] = nil }
    }

    static func recordLines(_ records: [HostServiceProtocol.TranscriptRecord]) -> Data {
        Data(records.map { "\($0.length)\t\($0.text)\n" }.joined().utf8)
    }
}

/// 一次尾端讀取的內容:檔案大小與游標之後的完整行。
struct TailAnswer {
    var size: Int
    var records: [HostServiceProtocol.TranscriptRecord]

    /// 與 SSH 追蹤腳本相同的輸出：大小一行，再接游標之後的完整行。
    var data: Data { Data("\(size)\n".utf8) + HTTPSHostConnection.recordLines(records) }
}

/// 一個追蹤中的對話紀錄：主機服務推送的完整行，從 `bufferStart` 起相連。
struct TranscriptFollow {
    let session: HostServiceSession
    let streamID: String
    private(set) var size = 0
    private(set) var ended: HostServiceProtocol.TranscriptStreamEnd?
    private var bufferStart: Int
    private var bufferEnd: Int
    private var records: [(offset: Int, record: HostServiceProtocol.TranscriptRecord)] = []
    private var bufferedBytes = 0

    /// 積壓超過這麼多 byte(app 很久沒讀)就不再回答，改重新開始追蹤。
    static let maximumBufferedBytes = 8 << 20

    init(session: HostServiceSession, streamID: String, cursor: Int) {
        self.session = session
        self.streamID = streamID
        bufferStart = cursor
        bufferEnd = cursor
    }

    mutating func apply(_ messages: [HostServiceProtocol.ServerMessage]) {
        for case .transcriptUpdate(let update) in messages {
            apply(size: update.size, start: update.start, records: update.records, ended: update.ended)
        }
    }

    mutating func apply(size: Int, start: Int, records added: [HostServiceProtocol.TranscriptRecord], ended: HostServiceProtocol.TranscriptStreamEnd?) {
        self.size = size
        self.ended = ended
        if start != bufferEnd {
            // 不相連(不該發生):從這裡重新累積。
            bufferStart = start
            bufferEnd = start
            records = []
            bufferedBytes = 0
        }
        for record in added {
            records.append((bufferEnd, record))
            bufferEnd += record.length + 1
            bufferedBytes += record.text.utf8.count
        }
    }

    /// 游標在收到的範圍內、落在行首。
    func canAnswer(from cursor: Int) -> Bool {
        guard bufferedBytes <= Self.maximumBufferedBytes, cursor >= bufferStart, cursor <= bufferEnd else { return false }
        return cursor == bufferEnd || records.contains { $0.offset == cursor }
    }

    /// 主機上的檔案大小與游標之後的完整行。
    func output(from cursor: Int) -> TailAnswer {
        TailAnswer(size: size, records: records.filter { $0.offset >= cursor }.map(\.record))
    }

    /// 丟掉游標之前已讀過的行。
    mutating func discard(before cursor: Int) {
        guard cursor > bufferStart, cursor <= bufferEnd else { return }
        let dropped = records.prefix { $0.offset < cursor }
        bufferedBytes -= dropped.reduce(0) { $0 + $1.record.text.utf8.count }
        records.removeFirst(dropped.count)
        bufferStart = cursor
    }
}

/// 一個追蹤串流(`HTTPSHostConnection.followTranscript`)。
struct TranscriptStream: Sendable {
    let id = UUID()
    let continuation: AsyncThrowingStream<TranscriptFollowEvent, any Error>.Continuation
}

/// 追蹤串流收到的推送換成事件：新增的完整行從 `position` 接著。
struct PushedTranscript {
    var position: Int

    /// 送出這則推送的事件;回傳追蹤是否結束。檔案不在或讀不了丟 `TranscriptReadError`。
    mutating func forward(
        size: Int, start: Int, records: [HostServiceProtocol.TranscriptRecord], ended: HostServiceProtocol.TranscriptStreamEnd?,
        to continuation: AsyncThrowingStream<TranscriptFollowEvent, any Error>.Continuation
    ) throws -> Bool {
        switch ended {
        case .absent: throw TranscriptReadError.absent
        case .unreadable: throw TranscriptReadError.unreadable
        default: break
        }
        guard start == position else {
            // 不相連(不該發生):接不上，讓呼叫端重讀視窗。
            continuation.yield(.replaced(size: size))
            return true
        }
        if !records.isEmpty {
            let end = position + records.reduce(0) { $0 + $1.length + 1 }
            continuation.yield(.appended(TranscriptChunk(start: position, end: end, lines: records.map(\.text))))
            position = end
        }
        guard ended != nil else { return false }
        // 換檔、變短，或 #173 之前的主機服務落後太多(too_far_behind):重讀視窗。
        continuation.yield(.replaced(size: size))
        return true
    }
}
