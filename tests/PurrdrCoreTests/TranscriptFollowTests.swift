import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 主機連線的對話紀錄追蹤(#165,spec #154):呼叫端只看 `.appended`／`.replaced` 事件，不知道背後是推送還是輪詢。
@Suite("對話紀錄追蹤")
struct TranscriptFollowTests {
    static let sessionID = "0000c1a0-0000-4000-8000-000000000001"
    static let relativePath = ".claude/projects/-Users-demo-Projects-ledger/\(sessionID).jsonl"
    static let firstLine = #"{"n":1}"#
    static let secondLine = #"{"n":2}"#

    static func line(_ text: String) -> Data { Data((text + "\n").utf8) }

    /// 只有 `wake()` 才讀：測試不必真的等間隔。
    static func manualPace() -> TranscriptFollowPace {
        TranscriptFollowPace(interval: .seconds(2), sleep: RecordingSleeper().sleep)
    }

    // MARK: - SSH(內部輪詢)

    @Test("SSH:有新增的完整行送 appended,範圍從游標接著")
    func sshSendsAppendedLines() async throws {
        let host = try LocalShellHost.temporary()
        let path = try host.write(Self.line(Self.firstLine), to: Self.relativePath).path(percentEncoded: false)
        let pace = Self.manualPace()
        var events = await SSHHostConnection(channel: host).followTranscript(path: path, from: 8, pace: pace).makeAsyncIterator()

        try host.append(Self.line(Self.secondLine), to: Self.relativePath)
        pace.wake()
        let event = try await events.next()

        #expect(event == .appended(TranscriptChunk(start: 8, end: 16, lines: [Self.secondLine])))
    }

    @Test("SSH:檔案被換成較短的新檔時送 replaced(新檔大小),追蹤結束")
    func sshSendsReplacedWhenFileShrinks() async throws {
        let host = try LocalShellHost.temporary()
        let path = try host.write(Self.line(Self.firstLine) + Self.line(Self.secondLine), to: Self.relativePath).path(percentEncoded: false)
        let pace = Self.manualPace()
        var events = await SSHHostConnection(channel: host).followTranscript(path: path, from: 16, pace: pace).makeAsyncIterator()

        _ = try host.write(Self.line("{}"), to: Self.relativePath)
        pace.wake()
        let event = try await events.next()
        let afterReplaced = try await events.next()

        #expect(event == .replaced(size: 3))
        #expect(afterReplaced == nil)
    }

    // MARK: - HTTPS(主機服務推送)

    static let httpsPath = "/Users/demo/\(relativePath)"

    static func followingService() async throws -> FakeHostService {
        try await FakeHostService.start(.init(transcriptReplies: [
            "transcript.follow": #"{"type":"transcript.follow.result","size":100,"start":100,"records":[]}"#,
            "transcript.unfollow": #"{"type":"transcript.unfollow.result"}"#,
        ]))
    }

    static func connection(to service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
    }

    static func streamID(of service: FakeHostService) async throws -> String {
        try await waitUntil { !service.messages(ofType: "transcript.follow").isEmpty }
        return try #require(service.messages(ofType: "transcript.follow").first?["stream_id"] as? String)
    }

    @Test("HTTPS:主機推送的新行直接變成 appended,不再送請求")
    func httpsForwardsPushedLines() async throws {
        let service = try await Self.followingService()
        defer { Task { await service.stop() } }
        var events = await Self.connection(to: service).followTranscript(path: Self.httpsPath, from: 100, pace: Self.manualPace()).makeAsyncIterator()
        let streamID = try await Self.streamID(of: service)
        let sentBeforePush = service.log.messages.count

        try await service.push(#"{"type":"transcript.update","stream_id":"\#(streamID)","size":125,"start":100,"records":[{"length":7,"text":"{\"n\":3}"},{"length":7,"text":"{\"n\":4}"}]}"#)
        let event = try await events.next()

        #expect(event == .appended(TranscriptChunk(start: 100, end: 116, lines: [#"{"n":3}"#, #"{"n":4}"#])))
        let follow = try #require(service.messages(ofType: "transcript.follow").first)
        #expect(follow["path"] as? String == Self.httpsPath)
        #expect(follow["from"] as? Int == 100)
        #expect(service.log.messages.count == sentBeforePush)
    }

    @Test("HTTPS:主機以 replaced 結束追蹤時送 replaced(新檔大小),追蹤結束")
    func httpsSendsReplacedWhenHostEndsWithReplaced() async throws {
        let service = try await Self.followingService()
        defer { Task { await service.stop() } }
        var events = await Self.connection(to: service).followTranscript(path: Self.httpsPath, from: 100, pace: Self.manualPace()).makeAsyncIterator()
        let streamID = try await Self.streamID(of: service)

        try await service.push(#"{"type":"transcript.update","stream_id":"\#(streamID)","size":140,"start":100,"records":[],"ended":"replaced"}"#)
        let event = try await events.next()
        let afterReplaced = try await events.next()

        #expect(event == .replaced(size: 140))
        #expect(afterReplaced == nil)
    }

    @Test("HTTPS:落後很多時主機分段送出(#173),每段都接成 appended,超大單行照原始長度前進，不取代畫面")
    func httpsAppendsEachCatchUpChunk() async throws {
        let service = try await Self.followingService()
        defer { Task { await service.stop() } }
        var events = await Self.connection(to: service).followTranscript(path: Self.httpsPath, from: 100, pace: Self.manualPace()).makeAsyncIterator()
        let streamID = try await Self.streamID(of: service)

        // 第一段：一行 300000 bytes 的超大單行，主機截短後送出;第二段從它的結尾(100 + 300000 + 1)接著。
        try await service.push(#"{"type":"transcript.update","stream_id":"\#(streamID)","size":900000,"start":100,"records":[{"length":300000,"text":"{\"type\":\"user\""}]}"#)
        try await service.push(#"{"type":"transcript.update","stream_id":"\#(streamID)","size":900000,"start":300101,"records":[{"length":7,"text":"{\"n\":3}"}]}"#)
        let first = try await events.next()
        let second = try await events.next()

        #expect(first == .appended(TranscriptChunk(start: 100, end: 300101, lines: [#"{"type":"user""#])))
        #expect(second == .appended(TranscriptChunk(start: 300101, end: 300109, lines: [#"{"n":3}"#])))
    }

    @Test("HTTPS:#173 之前的主機服務落後太多以 too_far_behind 結束：送 replaced,由呼叫端讀新視窗")
    func httpsTreatsLegacyTooFarBehindAsReplaced() async throws {
        let service = try await Self.followingService()
        defer { Task { await service.stop() } }
        var events = await Self.connection(to: service).followTranscript(path: Self.httpsPath, from: 100, pace: Self.manualPace()).makeAsyncIterator()
        let streamID = try await Self.streamID(of: service)

        try await service.push(#"{"type":"transcript.update","stream_id":"\#(streamID)","size":900000,"start":100,"records":[],"ended":"too_far_behind"}"#)
        let event = try await events.next()
        let afterEnded = try await events.next()

        #expect(event == .replaced(size: 900000))
        #expect(afterEnded == nil)
    }

    @Test("HTTPS:停止追蹤這個路徑：串流結束，請主機服務停止推送")
    func httpsStopFollowingEndsStreamAndUnfollows() async throws {
        let service = try await Self.followingService()
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)
        var events = await connection.followTranscript(path: Self.httpsPath, from: 100, pace: Self.manualPace()).makeAsyncIterator()
        let streamID = try await Self.streamID(of: service)

        await connection.stopFollowingTranscript(path: Self.httpsPath)
        let afterStop = try await events.next()

        #expect(afterStop == nil)
        try await waitUntil { !service.messages(ofType: "transcript.unfollow").isEmpty }
        #expect(service.messages(ofType: "transcript.unfollow").first?["stream_id"] as? String == streamID)
    }
}
