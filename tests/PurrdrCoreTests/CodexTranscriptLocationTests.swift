#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Codex rollout 的位置規則(行為規格 §4.2)。【未實測】位置依行為規格與 openai/codex 原始碼,
/// 在本機以 `LocalShellHost`(暫存家目錄)對同一份主機腳本驗證。
@Suite("對話紀錄定位:Codex")
struct CodexTranscriptLocationTests {
    static let id = "0000c0de-0000-4000-8000-000000000001"
    static let data = Fixtures.otherAgentTranscript("codex/rollout.jsonl")
    static let dated = ".codex/sessions/2026/11/14/rollout-2026-11-14T09-00-00-\(id).jsonl"

    static func agent(_ session: AgentSessionReference?) -> Agent {
        Agent(paneID: "w3:p1", workspaceID: "w3", kind: "codex", status: .idle, cwd: "/home/demo/notes", session: session)
    }

    static var target: TranscriptTarget {
        get throws { try #require(agent(AgentSessionReference(kind: "id", value: id)).transcriptTarget) }
    }

    @Test("Codex 的 session id 決定讀取目標;以路徑回報不接受")
    func sessionReferenceBecomesTarget() throws {
        let target = try Self.target
        #expect(target.format == .codex)
        #expect(target.location == .codex(sessionID: Self.id))
        #expect(target.sessionKey == Self.id)
        #expect(Self.agent(AgentSessionReference(kind: "path", value: "/home/demo/.codex/sessions/a.jsonl")).transcriptTarget == nil)
        #expect(Self.agent(AgentSessionReference(kind: "id", value: "x'; rm -rf ~")).transcriptTarget == nil)
    }

    @Test("在 sessions 的日期分層下找 rollout-*-<id>.jsonl")
    func findsDatedRollout() async throws {
        let host = try LocalShellHost.temporary()
        let url = try host.write(Self.data, to: Self.dated)
        try host.write(Self.data, to: ".codex/sessions/2026/11/14/rollout-2026-11-14T08-00-00-0000c0de-0000-4000-8000-000000000009.jsonl")

        let file = try await TranscriptReader(channel: host).locate(Self.target)

        #expect(file == TranscriptFile(path: url.path(percentEncoded: false), size: Self.data.count))
    }

    @Test("archived_sessions 也找")
    func findsArchivedRollout() async throws {
        let host = try LocalShellHost.temporary()
        let url = try host.write(Self.data, to: ".codex/archived_sessions/rollout-2026-11-14T09-00-00-\(Self.id).jsonl")

        let file = try await TranscriptReader(channel: host).locate(Self.target)

        #expect(file.path == url.path(percentEncoded: false))
    }

    @Test("沒有檔案是缺席;只有 .zst 是「已壓縮」,不是缺席")
    func absentAndCompressed() async throws {
        let host = try LocalShellHost.temporary()
        await #expect(throws: TranscriptReadError.absent) { try await TranscriptReader(channel: host).locate(Self.target) }

        try host.write(Data([0x28, 0xB5, 0x2F, 0xFD]), to: Self.dated + ".zst")
        await #expect(throws: TranscriptReadError.compressed) { try await TranscriptReader(channel: host).locate(Self.target) }
    }

    /// 倒帶會寫 `rollout-<ts>-<id>_<rolloutId>.jsonl` 並保留舊檔:沒有狀態資料庫可問時不開任何檔、不依新舊猜。
    @Test("不只一個 rollout 且沒有狀態資料庫 → 有歧義")
    func multipleRolloutsWithoutStateAreAmbiguous() async throws {
        let host = try LocalShellHost.temporary()
        try host.write(Self.data, to: Self.dated)
        try host.write(Self.data, to: ".codex/sessions/2026/11/15/rollout-2026-11-15T10-00-00-\(Self.id)_0000beef-0000-4000-8000-000000000002.jsonl")

        await #expect(throws: TranscriptReadError.ambiguous) { try await TranscriptReader(channel: host).locate(Self.target) }
    }

    @Test("不只一個 rollout 時以唯讀查 state_*.sqlite 的 threads.rollout_path,等於候選之一的勝出")
    func stateDatabasePicksRollout() async throws {
        let host = try LocalShellHost.temporary()
        try host.write(Self.data, to: Self.dated)
        let rewound = try host.write(Self.data, to: ".codex/sessions/2026/11/15/rollout-2026-11-15T10-00-00-\(Self.id)_0000beef-0000-4000-8000-000000000002.jsonl")
        let path = rewound.path(percentEncoded: false)
        try Self.sqlite(host.url(".codex/state_5.sqlite"), """
            create table threads (id text primary key, rollout_path text not null);
            insert into threads values ('\(Self.id)', '\(path)');
            insert into threads values ('other', '/nowhere.jsonl');
            """)

        let file = try await TranscriptReader(channel: host).locate(Self.target)

        #expect(file.path == path)
    }

    @Test("資料庫指向的不是候選之一(或 schema 不同)→ 仍然有歧義")
    func stateDatabaseMismatchStaysAmbiguous() async throws {
        let host = try LocalShellHost.temporary()
        try host.write(Self.data, to: Self.dated)
        try host.write(Self.data, to: ".codex/sessions/2026/11/15/rollout-2026-11-15T10-00-00-\(Self.id)_0000beef-0000-4000-8000-000000000002.jsonl")
        try Self.sqlite(host.url(".codex/state_5.sqlite"), "create table threads (id text, rollout_path text); insert into threads values ('\(Self.id)', '/elsewhere.jsonl');")
        try Self.sqlite(host.url(".codex/state_6.sqlite"), "create table other (x text);")

        await #expect(throws: TranscriptReadError.ambiguous) { try await TranscriptReader(channel: host).locate(Self.target) }
    }

    @Test("第一行的 session_meta id 與回報的不符 → 不符(下次重試)")
    func headerMismatch() async throws {
        let host = try LocalShellHost.temporary()
        let other = Self.data.replacing(Data(Self.id.utf8), with: Data("0000c0de-0000-4000-8000-00000000000f".utf8), maxReplacements: 1)
        try host.write(other, to: Self.dated)

        await #expect(throws: TranscriptReadError.mismatch) { try await TranscriptReader(channel: host).locate(Self.target) }
    }

    @Test("列表預覽:Codex 與 Claude 一次往返;header 不符的不預覽")
    func previews() async throws {
        let host = try LocalShellHost.temporary()
        try host.write(Self.data, to: Self.dated)
        let otherID = "0000c0de-0000-4000-8000-000000000002"
        try host.write(Self.data, to: ".codex/sessions/2026/11/14/rollout-2026-11-14T11-00-00-\(otherID).jsonl")
        let other = TranscriptTarget(format: .codex, location: .codex(sessionID: otherID), sessionKey: otherID)

        let previews = try await TranscriptReader(channel: host, marker: { "MARK" })
            .previews(of: [PreviewRequest(key: "w3:p1", target: Self.target), PreviewRequest(key: "w4:p1", target: other)])

        #expect(previews["w3:p1"]?.text == "Exported 2 notes to out/.")
        #expect(previews["w4:p1"] == nil)
        #expect(host.commands.count == 1)
    }

    @Test("列表預覽帶已知版本:Codex 附加的部分不重傳 header,沿用上次的 header 檢查")
    func previewAppendedSkipsHeader() async throws {
        let host = try LocalShellHost.temporary()
        try host.write(Self.data, to: Self.dated)
        let reader = TranscriptReader(channel: host, marker: { "MARK" })
        let first = try #require(try await reader.previewReadings(of: [PreviewRequest(key: "w3:p1", target: Self.target)])["w3:p1"])
        try host.append(Data(#"{"timestamp":"2026-11-14T09:00:21.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Done again."}]}}"#.utf8 + [0x0A]), to: Self.dated)
        var request = PreviewRequest(key: "w3:p1", target: try Self.target)
        request.knownVersion = first.version

        let again = try #require(try await reader.previewReadings(of: [request])["w3:p1"])

        #expect(again.change == .appended)
        #expect(again.preview?.text == "Done again.")
    }

    static func sqlite(_ url: URL, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [url.path(percentEncoded: false), sql]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
#endif
