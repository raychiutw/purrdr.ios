import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Workflow 卡與畫面的讀取(行為規格 F10「Workflow 卡/畫面」、R-W03)。run 檔與 journal 依 §4.6 寫成(作者 Mac 上沒有
/// workflow 紀錄,見 `Fixtures/README.md`)。
@MainActor
@Suite("Workflow 進度")
struct WorkflowModelTests {
    static let session = ".claude/projects/-Users-demo-Projects-ledger/00000000-0000-0000-0000-000000000002"
    static let journalPath = "\(session)/subagents/workflows/wf_demo01/journal.jsonl"
    static let runPath = "\(session)/workflows/wf_demo01.json"
    static let card = WorkflowCard(id: "w", callID: "toolu_demo_w1", name: "release-review", runID: "wf_demo01")

    static func setup() throws -> (LocalShellHost, WorkflowModel, TestClock) {
        let shell = try LocalShellHost.temporary()
        let clock = TestClock()
        let model = WorkflowModel(
            transcripts: TranscriptReader(channel: shell), sessionFolder: shell.home.appending(path: session).path(percentEncoded: false),
            card: card, clock: clock.clock
        )
        return (shell, model, clock)
    }

    @Test("執行中讀 journal:各 phase 與其中的 agent")
    func runningReadsJournal() async throws {
        let (shell, model, _) = try Self.setup()
        try shell.write(Fixtures.workflowFile("journal.jsonl"), to: Self.journalPath)

        await model.poll()

        #expect(model.run?.phases.map(\.title) == ["Check", "Review"])
        #expect(model.isTracking)
        #expect(model.run.flatMap(DelegationText.progress(of:)) == "1 of 3 agents done")
    }

    @Test("run 檔寫一半：保留上次成功的解析與舊 checksum(下次會再讀)")
    func tornRunFileKeepsLastParse() async throws {
        let (shell, model, _) = try Self.setup()
        try shell.write(Fixtures.workflowFile("journal.jsonl"), to: Self.journalPath)
        await model.poll()
        let journalRun = model.run
        let journalChecksum = model.checksum

        try shell.write(Fixtures.workflowFile("run.json").prefix(300), to: Self.runPath)
        await model.poll()
        #expect(model.run == journalRun)
        #expect(model.checksum == journalChecksum)

        try shell.write(Fixtures.workflowFile("run.json"), to: Self.runPath)
        await model.poll()
        #expect(model.run?.summary == "Checked the release notes, then reviewed their wording.")
    }

    @Test("結束：run 檔狀態不是執行中就停止追蹤")
    func stopsWhenRunFileFinished() async throws {
        let (shell, model, _) = try Self.setup()
        try shell.write(Fixtures.workflowFile("run.json"), to: Self.runPath)

        await model.poll()

        #expect(model.isTracking == false)
        #expect(model.stoppedTracking == false)
    }

    @Test("結束：對話紀錄說結束 → 再讀一次就停止")
    func transcriptEndReadsOnceMore() async throws {
        let (shell, model, _) = try Self.setup()
        try shell.write(Fixtures.workflowFile("journal.jsonl"), to: Self.journalPath)
        await model.poll()

        var ended = Self.card
        ended.status = .completed
        model.update(card: ended)
        #expect(model.isTracking)
        await model.poll()
        #expect(model.isTracking == false)
    }

    @Test("仍說執行中但 30 分鐘沒變化：停止追蹤並標示「不再追蹤」")
    func staleRunStopsTracking() async throws {
        let (shell, model, clock) = try Self.setup()
        try shell.write(Fixtures.workflowFile("journal.jsonl"), to: Self.journalPath)
        await model.poll()

        clock.advance(by: 29 * 60)
        await model.poll()
        #expect(model.isTracking)

        clock.advance(by: 2 * 60)
        await model.poll()
        #expect(model.isTracking == false)
        #expect(model.stoppedTracking)
    }

    @Test("沒有 run id(還沒拿到啟動結果)就不讀")
    func noRunIDNoRead() async throws {
        let shell = try LocalShellHost.temporary()
        let host = RoutingHost(shell: shell)
        var card = Self.card
        card.runID = nil
        let model = WorkflowModel(transcripts: TranscriptReader(channel: host), sessionFolder: "/Users/demo/s", card: card, clock: TestClock().clock)

        await model.poll()

        #expect(await host.shellCommands.isEmpty)
        #expect(model.run == nil)
    }

    @Test("HTTPS 主機的主機服務太舊：說明需要更新主機服務並停止追蹤")
    func outdatedHostServiceStopsWithReason() async throws {
        let connection = FakeHostConnection()
        await connection.stub(
            .workflow, failure: HostServiceError.hostServiceUpdateRequired(.transcriptPreviewsAndDelegations, installedVersion: "0.6.2"))
        let model = WorkflowModel(transcripts: TranscriptReader(connection: connection), sessionFolder: "/Users/demo/s", card: Self.card, clock: TestClock().clock)

        await model.poll()

        #expect(model.unavailableReason?.contains("0.6.2") == true)
        #expect(model.isTracking == false)
    }
}
