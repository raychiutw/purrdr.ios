import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Workflow run 檔與 journal(行為規格 §4.6「Workflow run 檔」「Journal」、F10「Workflow 卡/畫面」、R-W03)。
///
/// 作者 Mac 上沒有任何 `Workflow` 工具的紀錄(找過所有 `~/.claude/projects`),所以 `Fixtures/claude-code/workflow/`
/// 依行為規格 §4.6 描述的欄位寫成，不是錄製的(見 `Fixtures/README.md`)。
@Suite("Workflow run")
struct WorkflowRunTests {
    static let runFile = Fixtures.workflowFile("run.json")
    static let journal = String(decoding: Fixtures.workflowFile("journal.jsonl"), as: UTF8.self)
        .split(separator: "\n").map(String.init)

    @Test("run 檔：名稱、摘要、時長、tokens;agent 依 phase 分組，done/completed 完成、error 失敗")
    func parsesRunFile() throws {
        let run = try #require(WorkflowRun.parse(runFile: Self.runFile))

        #expect(run.name == "release-review")
        #expect(run.summary == "Checked the release notes, then reviewed their wording.")
        #expect(run.isRunning == false)
        #expect(run.durationMs == 125_000)
        #expect(run.totalTokens == 48200)
        #expect(run.logs == ["Started 3 agents", "All agents finished"])
        #expect(run.phases.map(\.title) == ["Check", "Review"])
        #expect(run.phases.map(\.detail) == ["Open every link in the release notes", "Read the notes for tone and typos"])
        #expect(run.phases.map { $0.agents.map(\.label) } == [["links", "images"], ["wording"]])
        #expect(run.agents.map(\.state) == [.completed, .failed, .completed])
        let links = run.agents[0]
        #expect(links.agentID == "aw0000000000000001")
        #expect(links.tokens == 15100)
        #expect(links.toolCalls == 9)
        #expect(links.activity == "WebFetch docs/release.md")
        #expect(links.resultPreview == "All 12 links work.")
        #expect(run.agents[1].error == "Image folder not found")
        #expect(run.completedAgents == 2)
    }

    @Test("run 檔狀態 running／pending／queued／started／沒有 都算執行中", arguments: ["\"running\"", "\"pending\"", "\"queued\"", "\"started\"", "null"])
    func runningStatuses(status: String) throws {
        let text = String(decoding: Self.runFile, as: UTF8.self).replacingOccurrences(of: "\"completed\",\n  \"phases\"", with: "\(status),\n  \"phases\"")
        let run = try #require(WorkflowRun.parse(runFile: Data(text.utf8)))

        #expect(run.isRunning)
    }

    @Test("寫一半的 run 檔解析不出來(呼叫端保留上次結果)")
    func tornRunFileIsNil() {
        #expect(WorkflowRun.parse(runFile: Self.runFile.prefix(300)) == nil)
    }

    @Test("journal:phase 依首次出現順序分組;有 result 即完成、有 error 失敗、其他執行中;撕裂的最後一行略過")
    func parsesJournal() {
        let run = WorkflowRun.parse(journal: Self.journal)

        #expect(run.isRunning)
        #expect(run.phases.map(\.title) == ["Check", "Review"])
        #expect(run.phases.map { $0.agents.map(\.label) } == [["links", "images"], ["wording"]])
        #expect(run.agents.map(\.state) == [.completed, .failed, .running])
        #expect(run.agents[0].resultPreview == "All 12 links work.")
        #expect(run.agents[1].error == "Image folder not found")
    }

    // MARK: - 主機讀取

    static let session = ".claude/projects/-Users-demo-Projects-ledger/00000000-0000-0000-0000-000000000002"

    static func folder(_ shell: LocalShellHost) -> String {
        shell.home.appending(path: session).path(percentEncoded: false)
    }

    @Test("讀取：執行中只有 journal → 讀 journal;run 檔出現後(結束時才寫)讀 run 檔")
    func readsJournalThenRunFile() async throws {
        let shell = try LocalShellHost.temporary()
        try shell.write(Fixtures.workflowFile("journal.jsonl"), to: "\(Self.session)/subagents/workflows/wf_demo01/journal.jsonl")
        let reader = TranscriptReader(channel: shell)

        guard case .journal(_, let lines) = try await reader.readWorkflow(sessionFolder: Self.folder(shell), runID: "wf_demo01", knownChecksum: nil) else {
            Issue.record("應讀到 journal")
            return
        }
        #expect(lines.count == 7)

        try shell.write(Self.runFile, to: "\(Self.session)/workflows/wf_demo01.json")
        guard case .run(_, let data) = try await reader.readWorkflow(sessionFolder: Self.folder(shell), runID: "wf_demo01", knownChecksum: nil) else {
            Issue.record("應讀到 run 檔")
            return
        }
        #expect(data == Self.runFile)
    }

    @Test("checksum 與上次相同就不傳內容;變了才傳")
    func unchangedChecksumSkipsContent() async throws {
        let shell = try LocalShellHost.temporary()
        try shell.write(Fixtures.workflowFile("journal.jsonl"), to: "\(Self.session)/subagents/workflows/wf_demo01/journal.jsonl")
        let reader = TranscriptReader(channel: shell)
        guard case .journal(let checksum, _) = try await reader.readWorkflow(sessionFolder: Self.folder(shell), runID: "wf_demo01", knownChecksum: nil) else {
            Issue.record("應讀到 journal")
            return
        }

        #expect(try await reader.readWorkflow(sessionFolder: Self.folder(shell), runID: "wf_demo01", knownChecksum: checksum) == .unchanged)

        try shell.append(Data("{\"type\":\"launched\"}\n".utf8), to: "\(Self.session)/subagents/workflows/wf_demo01/journal.jsonl")
        guard case .journal(let next, _) = try await reader.readWorkflow(sessionFolder: Self.folder(shell), runID: "wf_demo01", knownChecksum: checksum) else {
            Issue.record("內容變了應重讀")
            return
        }
        #expect(next != checksum)
    }

    @Test("兩個都還沒有是「缺席」;run id 不安全就拒絕")
    func absentAndUnsafe() async throws {
        let shell = try LocalShellHost.temporary()
        let reader = TranscriptReader(channel: shell)

        await #expect(throws: TranscriptReadError.absent) {
            try await reader.readWorkflow(sessionFolder: Self.folder(shell), runID: "wf_demo01", knownChecksum: nil)
        }
        await #expect(throws: TranscriptReadError.invalidReference) {
            try await reader.readWorkflow(sessionFolder: Self.folder(shell), runID: "../wf", knownChecksum: nil)
        }
    }
}
