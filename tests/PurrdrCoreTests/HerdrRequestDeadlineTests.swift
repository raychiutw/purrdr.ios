import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// herdr 單次請求一律有期限(#86):沒有等待參數的請求 20 秒;有等待參數的是 herdr 的等待加上緩衝，絕不比 herdr 先放棄。
/// herdr 卡住(bridge 開著卻不回應)以假主機「回應後保持開著」模擬。
@Suite("herdr 單次請求期限")
struct HerdrRequestDeadlineTests {
    /// 一種 herdr 單次請求：預期的期限，以及經正式程式路徑送出它的動作。
    struct StuckRequest: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let deadline: Duration
        let send: @Sendable (HerdrClient) async throws -> Void
    }

    static let stuckRequests: [StuckRequest] = [
        StuckRequest(testDescription: "session.snapshot", deadline: .seconds(20)) { _ = try await $0.snapshot() },
        StuckRequest(testDescription: "ping", deadline: .seconds(20)) { _ = try await $0.ping() },
        StuckRequest(testDescription: "integration.list", deadline: .seconds(20)) { _ = try await $0.integrations() },
        StuckRequest(testDescription: "pane.report_metadata(在場回報)", deadline: .seconds(20)) {
            try await $0.reportPresence(paneID: "w1:p1", model: "opus", seq: 1)
        },
        StuckRequest(testDescription: "pane.read", deadline: .seconds(20)) { _ = try await $0.readPane(paneID: "w1:p1") },
        StuckRequest(testDescription: "workspace.rename", deadline: .seconds(20)) { try await $0.renameWorkspace("w1", to: "ledger") },
        StuckRequest(testDescription: "workspace.close", deadline: .seconds(20)) { try await $0.closeWorkspace("w1") },
        StuckRequest(testDescription: "worktree.create", deadline: .seconds(20)) { _ = try await $0.createWorktree(from: "w1", branch: "fix") },
        StuckRequest(testDescription: "pane.send_keys", deadline: .seconds(20)) { try await $0.sendKeys(paneID: "w1:p1", keys: ["enter"]) },
        StuckRequest(testDescription: "agent.prompt(slash 指令，不等待)", deadline: .seconds(20)) {
            _ = try await $0.prompt(target: "w1:p1", text: "/help", wait: nil)
        },
        StuckRequest(testDescription: "agent.prompt(等待 30 秒 + 20 秒)", deadline: .seconds(50)) {
            _ = try await $0.prompt(target: "w1:p1", text: "hi", wait: .seconds(30))
        },
        StuckRequest(testDescription: "agent.wait(等待 30 秒 + 20 秒)", deadline: .seconds(50)) {
            _ = try await $0.waitForAgent(target: "w1:p1", until: [.done], timeout: .seconds(30))
        },
        StuckRequest(testDescription: "agent.start(等待 30 秒 + 60 秒)", deadline: .seconds(90)) {
            try await $0.startAgent(name: "claude", kind: "claude", paneID: "w1:p1", arguments: [], timeout: .seconds(30))
        },
        StuckRequest(testDescription: "workspace.create(60 秒)", deadline: .seconds(60)) {
            _ = try await $0.createWorkspace(cwd: "/Users/demo/Projects/ledger", label: nil)
        },
    ]

    @Test("herdr 卡住不回應：期限到時丟 HerdrError.deadlineExceeded 並關閉通道", arguments: stuckRequests)
    func stuckRequestTimesOut(_ stuck: StuckRequest) async throws {
        let host = FakeHost()
        await host.expect(HerdrCommand.bridge(), reply: FakeReply(keepsOpen: true))
        let sleeper = RecordingSleeper { $0 == stuck.deadline }
        let client = HerdrClient(channel: host, sleep: sleeper.sleep)

        let outcome = await boundedOutcome { try await stuck.send(client) }

        guard let outcome else {
            Issue.record("herdr 卡住後沒有在期限到時返回(期限 \(stuck.deadline);要求過的等待：\(await sleeper.requested))")
            return
        }
        #expect(throws: HerdrError.deadlineExceeded) { try outcome.get() }
        #expect(await host.waitUntilClosed(execution: 0))
        #expect(await sleeper.requested.contains(stuck.deadline))
    }

    @Test("外層取消：等 herdr 回應時立刻返回並關閉通道")
    func cancellationReturnsWhileWaitingForReply() async throws {
        let host = FakeHost()
        await host.expect(HerdrCommand.bridge(), reply: FakeReply(keepsOpen: true))
        let client = HerdrClient(channel: host, sleep: RecordingSleeper().sleep)
        let task = Task { _ = try await client.snapshot() }
        #expect(await host.waitForExecutions(1) == 1)

        task.cancel()

        let finished = await boundedOutcome { try await task.value }
        #expect(finished != nil, "取消後沒有立刻返回")
        #expect(throws: CancellationError.self) { try finished?.get() }
        #expect(await host.waitUntilClosed(execution: 0))
    }
}
