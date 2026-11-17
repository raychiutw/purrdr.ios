import Foundation
import PurrdrCore

/// HTTPS 的對話紀錄(#59):定位與視窗是單次請求;尾端由主機服務推送(`transcript.follow`),
/// `tail` 從推送累積的行回答，不必每次輪詢都經網路。回傳的格式與 SSH 的腳本輸出相同，`TranscriptReader` 照原樣解析。
extension HTTPSHostConnection {
    func transcript(_ request: TranscriptRequest) async throws -> Data {
        switch request {
        case .locateClaude(let sessionID, _):
            return try await withDeadline(HostCommandDeadline.standard) {
                try await self.locate(.init(kind: "id", value: sessionID), header: false)
            }
        case .locate(let location, let readsHeader):
            return try await withDeadline(HostCommandDeadline.standard) {
                try await self.locate(Self.sessionReference(location), header: readsHeader)
            }
        case .window(let path, let end, let lines, _):
            return try await withDeadline(HostCommandDeadline.maximumRead) {
                try await self.window(path: path, end: end, lines: lines)
            }
        case .tail(let path, let cursor, let limit):
            return try await withDeadline(HostCommandDeadline.standard) {
                try await self.tail(path: path, from: cursor, limit: limit)
            }
        case .previews, .findSubagent, .readWorkflow, .delegationLines:
            throw HostServiceError.unsupported("transcript")
        }
    }

    /// herdr 回報的 session 參照;主機服務依它與 snapshot 找檔，app 不送路徑規則。
    static func sessionReference(_ location: TranscriptTarget.Location) -> HostServiceProtocol.SessionReference {
        switch location {
        case .claude(let id, _), .grok(let id), .antigravity(let id), .piJournal(let id), .codex(let id): .init(kind: "id", value: id)
        case .reportedPath(let path): .init(kind: "path", value: path)
        }
    }

    /// 「路徑、大小、header 各一行」。
    private func locate(_ session: HostServiceProtocol.SessionReference, header: Bool) async throws -> Data {
        let reply = try await send { .transcriptLocate(.init(requestId: $0, session: session, header: header)) }
        guard case .transcriptLocateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return Data(([result.path, String(result.size)] + (result.header ?? [])).map { $0 + "\n" }.joined().utf8)
    }

    /// 「起點 終點」一行，再接範圍內的行。
    private func window(path: String, end: Int, lines: Int) async throws -> Data {
        let reply = try await send { .transcriptWindow(.init(requestId: $0, path: path, end: end, lines: lines)) }
        guard case .transcriptWindowResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return Data("\(result.start) \(result.end)\n".utf8) + Self.recordLines(result.records)
    }

    /// 「大小」一行，再接游標之後的完整行。追蹤中且游標在已收到的範圍內時不經網路;否則(第一次、換了游標、
    /// 重新連線、主機結束追蹤之後)開始新的追蹤。
    private func tail(path: String, from cursor: Int, limit: Int) async throws -> Data {
        if var follow = transcriptFollows.removeValue(forKey: path) {
            if await follow.session.isOpen, let pushed = await follow.session.takeStreamMessages(follow.streamID) {
                follow.apply(pushed)
                if follow.ended != nil || follow.canAnswer(from: cursor) {
                    return try await answer(follow, path: path, cursor: cursor)
                }
            }
            await stopFollowing(follow)
        }
        let session = try await liveSession()
        nextTranscriptStream += 1
        let streamID = "t\(nextTranscriptStream)"
        await session.openStream(streamID)
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
        if let pushed = await session.takeStreamMessages(streamID) { follow.apply(pushed) }
        return try await answer(follow, path: path, cursor: cursor)
    }

    /// 回答這次讀取;主機已結束追蹤就丟掉這個追蹤(下次重新開始),否則留著並丟掉游標之前的行。
    private func answer(_ follow: TranscriptFollow, path: String, cursor: Int) async throws -> Data {
        let output = follow.output(from: cursor)
        guard let ended = follow.ended else {
            var kept = follow
            kept.discard(before: cursor)
            transcriptFollows[path] = kept
            return output
        }
        await follow.session.closeStream(follow.streamID)
        switch ended {
        case .absent: throw TranscriptReadError.absent
        case .unreadable: throw TranscriptReadError.unreadable
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

    static func recordLines(_ records: [HostServiceProtocol.TranscriptRecord]) -> Data {
        Data(records.map { "\($0.length)\t\($0.text)\n" }.joined().utf8)
    }
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

    /// 與 SSH 追蹤腳本相同的輸出：大小一行，再接游標之後的完整行。
    func output(from cursor: Int) -> Data {
        Data("\(size)\n".utf8) + HTTPSHostConnection.recordLines(records.filter { $0.offset >= cursor }.map(\.record))
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
