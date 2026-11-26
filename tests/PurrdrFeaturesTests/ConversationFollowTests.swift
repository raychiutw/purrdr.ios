import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 對話關閉或換成另一個 session 時，告訴主機連線不再追蹤舊的對話紀錄(#59:HTTPS 據此請主機服務停止推送)。
@MainActor
@Suite("對話追蹤的結束")
struct ConversationFollowTests {
    static let paneID = "w1:p6"
    static let sessionID = "00000000-0000-0000-0000-000000000001"
    static let transcriptPath = ".claude/projects/-Users-demo-Projects-garden-journal/\(sessionID).jsonl"

    /// 轉送給 SSH 主機連線，並記下停止追蹤的路徑。
    actor StopRecordingConnection: ForwardingHostConnection {
        let base: any HostConnection
        private(set) var stoppedPaths: [String] = []

        init(_ base: any HostConnection) {
            self.base = base
        }

        func stopFollowingTranscript(path: String) async {
            stoppedPaths.append(path)
        }
    }

    struct Setup {
        let herdr: FakeHostConnection
        let transcripts: StopRecordingConnection
        let model: ConversationModel
    }

    static func setup() async throws -> Setup {
        let shell = try LocalShellHost.temporary()
        _ = try shell.write(Fixtures.transcript(), to: transcriptPath)
        let transcripts = StopRecordingConnection(SSHHostConnection(channel: RoutingHost(shell: shell)))
        let herdr = FakeHostConnection()
        let model = ConversationModel(
            client: HerdrClient(connection: herdr), transcripts: TranscriptReader(connection: transcripts), paneID: paneID,
            knownSessionID: sessionID, cache: InMemoryConversationCache(), clock: TestClock().clock
        )
        return Setup(herdr: herdr, transcripts: transcripts, model: model)
    }

    @Test("離開對話畫面(run 結束):停止追蹤目前的對話紀錄")
    func leavingConversationStopsFollowing() async throws {
        let setup = try await Self.setup()
        await setup.herdr.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))

        await setup.model.run(sleep: { _ in throw CancellationError() })

        #expect(setup.model.phase == .ready)
        let stopped = await setup.transcripts.stoppedPaths
        #expect(stopped.count == 1)
        #expect(stopped.first.map { $0.hasSuffix("\(Self.sessionID).jsonl") } == true)
    }

    @Test("換成另一個 session:停止追蹤舊的對話紀錄")
    func newSessionStopsFollowingOldTranscript() async throws {
        let setup = try await Self.setup()
        let snapshot = Fixtures.data("session.snapshot.ndjson")
        let rotated = Data(String(decoding: snapshot, as: UTF8.self)
            .replacingOccurrences(of: Self.sessionID, with: "00000000-0000-0000-0000-0000000000f1").utf8)
        await setup.herdr.expect(.snapshot, wire: snapshot)
        await setup.herdr.expect(.snapshot, wire: rotated)
        await setup.model.poll()
        #expect(await setup.transcripts.stoppedPaths.isEmpty)

        await setup.model.poll()

        var stopped: [String] = []
        for _ in 0..<100 where stopped.isEmpty {
            stopped = await setup.transcripts.stoppedPaths
            await Task.yield()
        }
        #expect(stopped.count == 1)
        #expect(stopped.first.map { $0.hasSuffix("\(Self.sessionID).jsonl") } == true)
    }
}
