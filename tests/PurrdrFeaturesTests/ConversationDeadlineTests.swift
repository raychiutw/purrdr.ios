import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機上的對話紀錄指令卡住時(#91、spec #86):期限到就顯示讀取失敗、離開載入中，下一次輪詢主機正常就出現對話。
@MainActor
@Suite("對話閱讀：主機指令期限")
struct ConversationDeadlineTests {
    static let bridge = HerdrCommand.bridge()
    static let paneID = "w1:p6"
    static let sessionID = "00000000-0000-0000-0000-000000000001"
    static let cwd = "/Users/demo/Projects/garden-journal"
    static let transcriptPath = "/Users/demo/.claude/projects/-Users-demo-Projects-garden-journal/\(sessionID).jsonl"
    static let locate = TranscriptCommand.locate(sessionID: sessionID, projectFolder: ClaudeTranscript.projectFolder(forCWD: cwd))
    /// fixture 轉成的對話項目數(見 `ClaudeTranscriptParserTests.fixtureBecomesConversationItems`)。
    static let fixtureItemCount = 13

    /// 主機視窗腳本對整個 fixture 的輸出：`起點 終點`,之後每行 `原始長度 TAB 行`。
    static func windowOutput(of transcript: Data) -> Data {
        var output = Data("0 \(transcript.count)\n".utf8)
        for line in transcript.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            output.append(Data("\(line.count)\t".utf8))
            output.append(Data(line))
            output.append(0x0A)
        }
        return output
    }

    @Test("定位卡住：期限到時顯示讀取失敗、離開載入中;下一次輪詢主機正常就出現對話")
    func stuckLocateShowsReadFailedThenRecovers() async throws {
        let transcript = Fixtures.transcript()
        let host = FakeHost()
        let sleeper = RecordingSleeper { $0 == HostCommandDeadline.standard }
        let model = ConversationModel(
            client: HerdrClient(channel: host), transcripts: TranscriptReader(channel: host, sleep: sleeper.sleep), paneID: Self.paneID,
            knownSessionID: Self.sessionID, cache: InMemoryConversationCache(), clock: TestClock().clock
        )
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await host.expect(Self.locate, reply: FakeReply(keepsOpen: true))

        #expect(await boundedOutcome { await model.poll() } != nil, "定位卡住後輪詢沒有在期限到時結束")

        #expect(model.banner == .readFailed)
        #expect(model.phase == .ready)
        #expect(model.items.isEmpty)
        #expect(await host.waitUntilClosed(execution: 1))

        await sleeper.stopFiring()
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await host.expect(Self.locate, reply: FakeReply(stdout: Data("\(Self.transcriptPath)\n\(transcript.count)\n".utf8)))
        await host.expect(
            TranscriptCommand.window(path: Self.transcriptPath, end: transcript.count, lines: 300),
            reply: FakeReply(stdout: Self.windowOutput(of: transcript)))

        await model.poll()

        #expect(model.banner == nil)
        #expect(model.items.count == Self.fixtureItemCount)
        #expect(await host.unmetExpectations.isEmpty)
    }
}
