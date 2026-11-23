import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Grok、Antigravity、Pi／OMP 對話紀錄的位置規則(行為規格 §4.0、§4.3–4.5)。【未實測】位置依行為規格與各 agent 文件,
/// 在本機以 `LocalShellHost`(暫存家目錄)對同一份主機腳本驗證。
@Suite("對話紀錄定位：其他 agent")
struct OtherAgentTranscriptLocationTests {
    static let grokID = "0000a0c0-0000-4000-8000-000000000001"
    static let agyID = "0000a6e0-0000-4000-8000-000000000001"
    static let piID = "0000b0b0-0000-4000-8000-000000000001"

    static func agent(_ kind: String, _ session: AgentSessionReference?, cwd: String = "/home/demo/ledger") -> Agent {
        Agent(paneID: "w1:p1", workspaceID: "w1", kind: kind, status: .idle, cwd: cwd, session: session)
    }

    static func id(_ value: String) -> AgentSessionReference { AgentSessionReference(kind: "id", value: value) }
    static func path(_ value: String) -> AgentSessionReference { AgentSessionReference(kind: "path", value: value) }

    // MARK: - session 參照 → 讀取目標

    /// R-I02、R-I12:沒有 session 不讀;id 必須安全;只有 agy、Pi、OMP 接受以路徑回報，路徑要通過檢查。
    @Test("Agent 的 session 參照決定讀哪個檔;不安全或不接受的參照沒有目標")
    func sessionReferenceBecomesTarget() {
        let grok = Self.agent("grok", Self.id(Self.grokID)).transcriptTarget
        #expect(grok?.dialect == .grok)
        #expect(grok?.location == .id(.grok, Self.grokID))
        #expect(grok?.sessionKey == Self.grokID)
        #expect(Self.agent("agy", Self.id(Self.agyID)).transcriptTarget?.location == .id(.antigravity, Self.agyID))
        #expect(Self.agent("pi", Self.id(Self.piID)).transcriptTarget?.location == .id(.piJournal, Self.piID))
        #expect(Self.agent("omp", Self.path("/home/demo/.omp/agent/sessions/x/a.jsonl")).transcriptTarget?.location
            == .path("/home/demo/.omp/agent/sessions/x/a.jsonl", readsHeader: true))
        #expect(Self.agent("agy", Self.path("/home/demo/t.jsonl")).transcriptTarget?.sessionKey == "/home/demo/t.jsonl")
        #expect(Self.agent("claude", Self.id("abc-1"), cwd: "/home/demo").transcriptTarget?.location == .id(.claude, "abc-1", cwd: "/home/demo"))

        #expect(Self.agent("grok", Self.path("/home/demo/updates.jsonl")).transcriptTarget == nil)
        #expect(Self.agent("claude", Self.path("/home/demo/x.jsonl")).transcriptTarget == nil)
        #expect(Self.agent("pi", Self.path("relative/x.jsonl")).transcriptTarget == nil)
        #expect(Self.agent("pi", Self.path("/home/demo/../etc/x.jsonl")).transcriptTarget == nil)
        #expect(Self.agent("pi", Self.path("/home/demo/x.json")).transcriptTarget == nil)
        #expect(Self.agent("grok", Self.id("x; rm -rf ~")).transcriptTarget == nil)
        #expect(Self.agent("grok", nil).transcriptTarget == nil)
        #expect(Self.agent("opencode", Self.id("abc")).transcriptTarget == nil)
    }

    // MARK: - Grok

    @Test("Grok:在 sessions 下找深度剛好 2、名稱等於 id 的資料夾，讀其中的 updates.jsonl")
    func grokFindsSessionFolder() async throws {
        let host = try LocalShellHost.temporary()
        let data = Fixtures.otherAgentTranscript("grok/updates.jsonl")
        let url = try host.write(data, to: ".grok/sessions/-home-demo-ledger/\(Self.grokID)/updates.jsonl")
        try host.write(data, to: ".grok/sessions/-home-demo-ledger/ffffffff-0000-4000-8000-000000000009/updates.jsonl")

        let file = try await TranscriptReader(channel: host).locate(#require(Self.agent("grok", Self.id(Self.grokID)).transcriptTarget))

        #expect(file == TranscriptFile(path: url.path(percentEncoded: false), size: data.count))
    }

    @Test("Grok:沒有資料夾是缺席，同名資料夾不只一個是有歧義(不猜)")
    func grokAbsentAndAmbiguous() async throws {
        let host = try LocalShellHost.temporary()
        let target = try #require(Self.agent("grok", Self.id(Self.grokID)).transcriptTarget)
        await #expect(throws: TranscriptReadError.absent) { try await TranscriptReader(channel: host).locate(target) }

        try host.write(Data("{}\n".utf8), to: ".grok/sessions/-home-demo-ledger/\(Self.grokID)/updates.jsonl")
        try host.write(Data("{}\n".utf8), to: ".grok/sessions/-home-demo-ledger-2/\(Self.grokID)/updates.jsonl")
        await #expect(throws: TranscriptReadError.ambiguous) { try await TranscriptReader(channel: host).locate(target) }
    }

    // MARK: - Antigravity

    @Test("Antigravity:id → brain/<id>/.system_generated/logs/transcript.jsonl(不搜尋)")
    func antigravityByID() async throws {
        let host = try LocalShellHost.temporary()
        let data = Fixtures.otherAgentTranscript("antigravity/transcript.jsonl")
        let url = try host.write(data, to: ".gemini/antigravity-cli/brain/\(Self.agyID)/.system_generated/logs/transcript.jsonl")

        let file = try await TranscriptReader(channel: host).locate(#require(Self.agent("agy", Self.id(Self.agyID)).transcriptTarget))

        #expect(file == TranscriptFile(path: url.path(percentEncoded: false), size: data.count))
    }

    @Test("Antigravity:回報的路徑直接用;檔案還沒寫出來是缺席")
    func antigravityByReportedPath() async throws {
        let host = try LocalShellHost.temporary()
        let data = Fixtures.otherAgentTranscript("antigravity/transcript.jsonl")
        let url = try host.write(data, to: "elsewhere/transcript.jsonl")
        let path = url.path(percentEncoded: false)

        let file = try await TranscriptReader(channel: host).locate(#require(Self.agent("agy", Self.path(path)).transcriptTarget))
        #expect(file == TranscriptFile(path: path, size: data.count))

        let missing = try #require(Self.agent("agy", Self.path(path + "-not-yet.jsonl")).transcriptTarget)
        await #expect(throws: TranscriptReadError.absent) { try await TranscriptReader(channel: host).locate(missing) }
    }

    // MARK: - Pi／OMP

    @Test("Pi:id → 在 Pi 的 sessions 下找 <時間>_<id>.jsonl,並檢查 header 的 session id")
    func piFindsJournalByID() async throws {
        let host = try LocalShellHost.temporary()
        let data = Fixtures.otherAgentTranscript("pi/session.jsonl")
        let url = try host.write(data, to: ".pi/agent/sessions/--home-demo-ledger--/2026-10-14T09-00-00-000Z_\(Self.piID).jsonl")

        let file = try await TranscriptReader(channel: host).locate(#require(Self.agent("pi", Self.id(Self.piID)).transcriptTarget))

        #expect(file == TranscriptFile(path: url.path(percentEncoded: false), size: data.count))
    }

    /// OMP 在 session header 前多一行固定寬度的標題槽。
    @Test("OMP:id → 在 ~/.omp/agent 下找 <id>.jsonl;第一行是標題時檢查第二行")
    func ompFindsJournalWithTitleLine() async throws {
        let host = try LocalShellHost.temporary()
        let data = Data(#"{"type":"title","title":"March receipts                "}"#.utf8) + [0x0A] + Fixtures.otherAgentTranscript("pi/session.jsonl")
        let url = try host.write(data, to: ".omp/agent/sessions/home-demo-ledger/\(Self.piID).jsonl")

        let file = try await TranscriptReader(channel: host).locate(#require(Self.agent("omp", Self.id(Self.piID)).transcriptTarget))

        #expect(file.path == url.path(percentEncoded: false))
    }

    @Test("Pi:header 的 session id 不符是不符錯誤;找到兩個檔是有歧義")
    func piHeaderMismatchAndAmbiguity() async throws {
        let host = try LocalShellHost.temporary()
        let other = Data(#"{"type":"session","version":3,"id":"ffffffff-0000-4000-8000-000000000009","timestamp":"2026-10-14T09:00:00.000Z"}"#.utf8) + [0x0A]
        try host.write(other, to: ".pi/agent/sessions/--home-demo-ledger--/a_\(Self.piID).jsonl")
        let target = try #require(Self.agent("pi", Self.id(Self.piID)).transcriptTarget)
        await #expect(throws: TranscriptReadError.mismatch) { try await TranscriptReader(channel: host).locate(target) }

        try host.write(other, to: ".omp/agent/sessions/home-demo-ledger/\(Self.piID).jsonl")
        await #expect(throws: TranscriptReadError.ambiguous) { try await TranscriptReader(channel: host).locate(target) }
    }

    // MARK: - 列表預覽

    /// §4.7:所有 agent 的預覽仍是一次往返;Pi／OMP 另含 header 檢查;一個請求失敗(缺席、有歧義、不符)不影響其他請求。
    @Test("預覽：Claude、Grok、Pi 混在一次往返;header 不符或缺席的沒有預覽")
    func previewsCoverAllReadableAgents() async throws {
        let shell = try LocalShellHost.temporary()
        try shell.write(Fixtures.transcript(), to: ".claude/projects/-home-demo-ledger/0000c1a0-0000-4000-8000-000000000001.jsonl")
        try shell.write(Fixtures.otherAgentTranscript("grok/updates.jsonl"), to: ".grok/sessions/x/\(Self.grokID)/updates.jsonl")
        try shell.write(Fixtures.otherAgentTranscript("pi/session.jsonl"), to: ".pi/agent/sessions/--home-demo-ledger--/t_\(Self.piID).jsonl")
        let otherPi = "0000b0b0-0000-4000-8000-000000000002"
        try shell.write(Fixtures.otherAgentTranscript("pi/session.jsonl"), to: ".pi/agent/sessions/--home-demo-ledger--/t_\(otherPi).jsonl")
        let host = RoutingHost(shell: shell)
        let agents = [
            ("w1:p1", Self.agent("claude", Self.id("0000c1a0-0000-4000-8000-000000000001"))),
            ("w2:p1", Self.agent("grok", Self.id(Self.grokID))),
            ("w3:p1", Self.agent("pi", Self.id(Self.piID))),
            ("w4:p1", Self.agent("pi", Self.id(otherPi))),
            ("w5:p1", Self.agent("agy", Self.id(Self.agyID))),
        ]
        let requests = try agents.map { try PreviewRequest(key: $0.0, target: #require($0.1.transcriptTarget)) }

        let previews = try await TranscriptReader(channel: host, marker: { "MARK-1234" }).previewReadings(of: requests).compactMapValues(\.preview)

        #expect(await host.shellCommands.count == 1)
        #expect(previews.keys.sorted() == ["w1:p1", "w2:p1", "w3:p1"])
        #expect(previews["w2:p1"]?.text == "The total floored half cents. It now rounds in totals.ts; one test still fails on negative amounts.")
        #expect(previews["w3:p1"]?.text == "Starting on April")
        #expect(previews["w3:p1"]?.isFromUser == false)
    }

    @Test("Pi:回報的路徑也要有 session header(不比對 id)")
    func piReportedPathNeedsHeader() async throws {
        let host = try LocalShellHost.temporary()
        let good = try host.write(Fixtures.otherAgentTranscript("pi/session.jsonl"), to: "custom/a.jsonl").path(percentEncoded: false)
        let bad = try host.write(Data(#"{"type":"message","id":"x"}"#.utf8 + [0x0A]), to: "custom/b.jsonl").path(percentEncoded: false)

        let file = try await TranscriptReader(channel: host).locate(#require(Self.agent("pi", Self.path(good)).transcriptTarget))
        #expect(file.path == good)
        let target = try #require(Self.agent("pi", Self.path(bad)).transcriptTarget)
        await #expect(throws: TranscriptReadError.mismatch) { try await TranscriptReader(channel: host).locate(target) }
    }
}
