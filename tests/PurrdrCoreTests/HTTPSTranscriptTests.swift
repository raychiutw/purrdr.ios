import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 對話閱讀(#59):`TranscriptReader` 經 HTTPS 主機連線讀對話紀錄，結果與 SSH 路線相同;
/// 尾端由主機服務推送，app 只在開始與停止追蹤時送請求。
@Suite("HTTPS 對話閱讀")
struct HTTPSTranscriptTests {
    static let sessionID = "00000000-0000-0000-0000-000000000001"
    static let path = "/Users/demo/.claude/projects/-Users-demo-Projects-garden-journal/\(sessionID).jsonl"

    private static func reader(for service: FakeHostService) -> (TranscriptReader, HTTPSHostConnection) {
        let connection = HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
        return (TranscriptReader(connection: connection), connection)
    }

    private static func start(_ replies: [String: String]) async throws -> FakeHostService {
        try await FakeHostService.start(.init(transcriptReplies: replies))
    }

    /// 等到條件成立(推送與不等待的請求是非同步到達的)。
    private static func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("定位：只送 herdr 回報的 session,不送路徑;回傳主機服務找到的檔案與大小")
    func locateSendsSessionNotPath() async throws {
        let service = try await Self.start([
            "transcript.locate": #"{"type":"transcript.locate.result","path":"\#(Self.path)","size":48213}"#,
        ])
        defer { Task { await service.stop() } }

        let file = try await Self.reader(for: service).0.locate(sessionID: Self.sessionID, cwd: "/Users/demo/Projects/garden-journal")

        #expect(file == TranscriptFile(path: Self.path, size: 48213))
        let sent = try #require(service.messages(ofType: "transcript.locate").first)
        #expect(sent["session"] as? [String: String] == ["kind": "id", "value": Self.sessionID])
        #expect(sent["header"] as? Bool == false)
        #expect(sent["path"] == nil)
    }

    @Test("Codex 定位要求 header,讀取端照 SSH 的規則檢查 session_meta")
    func codexLocateChecksHeader() async throws {
        let id = "019a5b2c-0000-7000-8000-000000000042"
        let rollout = "/Users/demo/.codex/sessions/2026/11/17/rollout-2026-11-17T10-00-00-\(id).jsonl"
        let meta = #"{\"type\":\"session_meta\",\"payload\":{\"id\":\"\#(id)\"}}"#
        let service = try await Self.start([
            "transcript.locate": #"{"type":"transcript.locate.result","path":"\#(rollout)","size":900,"header":["\#(meta)","{}"]}"#,
        ])
        defer { Task { await service.stop() } }

        let file = try await Self.reader(for: service).0.locate(TranscriptTarget(format: .codex, location: .codex(sessionID: id), sessionKey: id))

        #expect(file == TranscriptFile(path: rollout, size: 900))
        let sent = try #require(service.messages(ofType: "transcript.locate").first)
        #expect(sent["session"] as? [String: String] == ["kind": "id", "value": id])
        #expect(sent["header"] as? Bool == true)
    }

    @Test("Pi 以路徑回報的 session 照原樣送出 kind path")
    func reportedPathSession() async throws {
        let journal = "/Users/demo/.pi/agent/sessions/2026-11-17_abc.jsonl"
        let header = #"{\"type\":\"session\",\"id\":\"abc\"}"#
        let service = try await Self.start([
            "transcript.locate": #"{"type":"transcript.locate.result","path":"\#(journal)","size":3,"header":["\#(header)"]}"#,
        ])
        defer { Task { await service.stop() } }

        _ = try? await Self.reader(for: service).0.locate(TranscriptTarget(format: .piJournal, location: .reportedPath(journal), sessionKey: journal))

        let sent = try #require(service.messages(ofType: "transcript.locate").first)
        #expect(sent["session"] as? [String: String] == ["kind": "path", "value": journal])
    }

    @Test("視窗：主機服務的紀錄換成與 SSH 相同的範圍與行")
    func windowMatchesSSHChunk() async throws {
        let service = try await Self.start([
            "transcript.window": #"{"type":"transcript.window.result","start":100,"end":130,"records":[{"length":20,"text":"{\"n\":1}"},{"length":8,"text":"{\"n\":2}"}]}"#,
        ])
        defer { Task { await service.stop() } }

        let chunk = try await Self.reader(for: service).0.window(path: Self.path, endingAt: 140, lines: 300)

        #expect(chunk == TranscriptChunk(start: 100, end: 130, lines: [#"{"n":1}"#, #"{"n":2}"#]))
        let sent = try #require(service.messages(ofType: "transcript.window").first)
        #expect(sent["path"] as? String == Self.path)
        #expect(sent["end"] as? Int == 140)
        #expect(sent["lines"] as? Int == 300)
    }

    @Test("追蹤：第一次讀開始追蹤;之後主機推送的新行直接讀到，不再送請求")
    func tailReadsPushedLinesWithoutRequests() async throws {
        let service = try await Self.start([
            "transcript.follow": #"{"type":"transcript.follow.result","size":100,"start":100,"records":[]}"#,
        ])
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service).0

        let first = try await reader.tail(path: Self.path, from: 100)
        let follow = try #require(service.messages(ofType: "transcript.follow").first)
        let streamID = try #require(follow["stream_id"] as? String)
        try await service.push(#"{"type":"transcript.update","stream_id":"\#(streamID)","size":125,"start":100,"records":[{"length":7,"text":"{\"n\":3}"},{"length":7,"text":"{\"n\":4}"}]}"#)
        var pushed = TranscriptTail.unchanged
        let arrived = try await Self.eventually {
            pushed = try await reader.tail(path: Self.path, from: 100)
            return pushed != .unchanged
        }
        let messageCount = service.log.messages.count
        let afterCursor = try await reader.tail(path: Self.path, from: 108)

        #expect(first == .unchanged)
        #expect(follow["path"] as? String == Self.path)
        #expect(follow["from"] as? Int == 100)
        #expect(follow["limit"] as? Int == 64 << 10)
        #expect(arrived)
        #expect(pushed == .appended(TranscriptChunk(start: 100, end: 116, lines: [#"{"n":3}"#, #"{"n":4}"#])))
        #expect(afterCursor == .appended(TranscriptChunk(start: 108, end: 116, lines: [#"{"n":4}"#])))
        #expect(service.messages(ofType: "transcript.follow").count == 1)
        #expect(service.log.messages.count == messageCount)
    }

    @Test("對話紀錄換新：主機推送 shrank 後讀到 shrank,下一次讀重新開始追蹤")
    func shrankEndsStreamAndNextTailFollowsAgain() async throws {
        let service = try await Self.start([
            "transcript.follow": #"{"type":"transcript.follow.result","size":100,"start":100,"records":[]}"#,
        ])
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service).0
        _ = try await reader.tail(path: Self.path, from: 100)
        let streamID = try #require(service.messages(ofType: "transcript.follow").first?["stream_id"] as? String)

        try await service.push(#"{"type":"transcript.update","stream_id":"\#(streamID)","size":12,"start":100,"records":[],"ended":"shrank"}"#)
        var replaced = TranscriptTail.unchanged
        let arrived = try await Self.eventually {
            replaced = try await reader.tail(path: Self.path, from: 100)
            return replaced != .unchanged
        }
        _ = try await reader.tail(path: Self.path, from: 0)

        #expect(arrived)
        #expect(replaced == .shrank(size: 12))
        let follows = service.messages(ofType: "transcript.follow")
        #expect(follows.count == 2)
        #expect(follows.last?["from"] as? Int == 0)
        #expect(follows.last?["stream_id"] as? String != streamID)
    }

    @Test("對話紀錄被換成同長或更長的新檔：主機推送 replaced 後讀到 shrank(新檔大小),由上層重讀視窗")
    func replacedByLongerFileReadsAsShrank() async throws {
        let service = try await Self.start([
            "transcript.follow": #"{"type":"transcript.follow.result","size":100,"start":100,"records":[]}"#,
        ])
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service).0
        _ = try await reader.tail(path: Self.path, from: 100)
        let streamID = try #require(service.messages(ofType: "transcript.follow").first?["stream_id"] as? String)

        try await service.push(#"{"type":"transcript.update","stream_id":"\#(streamID)","size":140,"start":100,"records":[],"ended":"replaced"}"#)
        var replaced = TranscriptTail.unchanged
        let arrived = try await Self.eventually {
            replaced = try await reader.tail(path: Self.path, from: 100)
            return replaced != .unchanged
        }

        #expect(arrived)
        #expect(replaced == .shrank(size: 140))
    }

    @Test("落後太多：主機一開始就結束追蹤，讀到 tooFarBehind")
    func tooFarBehind() async throws {
        let service = try await Self.start([
            "transcript.follow": #"{"type":"transcript.follow.result","size":900000,"start":100,"records":[],"ended":"too_far_behind"}"#,
        ])
        defer { Task { await service.stop() } }

        let tail = try await Self.reader(for: service).0.tail(path: Self.path, from: 100)

        #expect(tail == .tooFarBehind(size: 900000))
    }

    @Test("分段接著讀(#173):落後超過上限時主機送出第一段，讀到 appended(超大單行照原始長度前進),不是落後太多")
    func catchUpReadsFirstChunkWhenFarBehind() async throws {
        let service = try await Self.start([
            "transcript.follow": #"{"type":"transcript.follow.result","size":900000,"start":100,"records":[{"length":300000,"text":"{\"type\":\"user\""}]}"#,
        ])
        defer { Task { await service.stop() } }

        let tail = try await Self.reader(for: service).0.catchUp(path: Self.path, from: 100)

        #expect(tail == .appended(TranscriptChunk(start: 100, end: 300101, lines: [#"{"type":"user""#])))
        #expect(service.messages(ofType: "transcript.follow").first?["limit"] as? Int == TranscriptReader.catchUpLimit)
    }

    @Test("關閉對話：送出 unfollow,主機停止追蹤")
    func stopFollowingSendsUnfollow() async throws {
        let service = try await Self.start([
            "transcript.follow": #"{"type":"transcript.follow.result","size":100,"start":100,"records":[]}"#,
            "transcript.unfollow": #"{"type":"transcript.unfollow.result"}"#,
        ])
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service).0
        _ = try await reader.tail(path: Self.path, from: 100)
        let streamID = try #require(service.messages(ofType: "transcript.follow").first?["stream_id"] as? String)

        await reader.stopFollowing(path: Self.path)
        let sent = try await Self.eventually { !service.messages(ofType: "transcript.unfollow").isEmpty }

        #expect(sent)
        #expect(service.messages(ofType: "transcript.unfollow").first?["stream_id"] as? String == streamID)
    }

    @Test("同一個對話紀錄同時開了兩個追蹤：只留一個，另一個請主機停止")
    func concurrentFollowsKeepOne() async throws {
        let service = try await Self.start([
            "transcript.follow": #"{"type":"transcript.follow.result","size":100,"start":100,"records":[]}"#,
            "transcript.unfollow": #"{"type":"transcript.unfollow.result"}"#,
        ])
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service).0

        async let first = reader.tail(path: Self.path, from: 100)
        async let second = reader.tail(path: Self.path, from: 100)
        _ = try await (first, second)
        let stopped = try await Self.eventually { !service.messages(ofType: "transcript.unfollow").isEmpty }

        let follows = service.messages(ofType: "transcript.follow").compactMap { $0["stream_id"] as? String }
        let unfollows = service.messages(ofType: "transcript.unfollow").compactMap { $0["stream_id"] as? String }
        #expect(follows.count == 2)
        #expect(stopped)
        #expect(unfollows.count == 1)
        #expect(unfollows.allSatisfy(follows.contains))
    }

    @Test(
        "主機服務回報的失敗對應到與 SSH 相同的對話紀錄錯誤種類",
        arguments: [
            ("transcript_absent", TranscriptReadError.absent),
            ("transcript_unreadable", .unreadable),
            ("transcript_ambiguous", .ambiguous),
            ("transcript_compressed", .compressed),
            ("transcript_not_allowed", .invalidReference),
        ])
    func failures(code: String, expected: TranscriptReadError) async throws {
        let service = try await Self.start([
            "transcript.locate": #"{"type":"error","code":"\#(code)","message":"failed"}"#,
        ])
        defer { Task { await service.stop() } }

        await #expect(throws: expected) {
            try await Self.reader(for: service).0.locate(sessionID: Self.sessionID, cwd: "/Users/demo/Projects/garden-journal")
        }
    }

    @Test("主機服務還讀不了的 agent:錯誤種類是 unsupported")
    func unsupportedAgent() async throws {
        let service = try await Self.start([
            "transcript.locate": #"{"type":"error","code":"transcript_unsupported","message":"failed"}"#,
        ])
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.unsupported("transcript")) {
            try await Self.reader(for: service).0.locate(TranscriptTarget(format: .grok, location: .grok(sessionID: "abc"), sessionKey: "abc"))
        }
    }
}
