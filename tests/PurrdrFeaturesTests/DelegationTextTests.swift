import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 卡片與背景 agents 列的文字(行為規格 F10 的數字格式與收合摘要)。UI 字串目前是英文(String Catalog 在 #30)。
@Suite("委派的文字")
struct DelegationTextTests {
    @Test("時長：<1s / 48s / 1m 6s / 1h 2m", arguments: [(0.4, "<1s"), (48, "48s"), (66, "1m 6s"), (60, "1m 0s"), (3720, "1h 2m"), (5460, "1h 31m")])
    func duration(seconds: Double, text: String) {
        #expect(DelegationText.duration(seconds) == text)
    }

    @Test("tokens:940 / 21.5k / 1.2M tokens", arguments: [(940, "940 tokens"), (21500, "21.5k tokens"), (64882, "64.9k tokens"), (1_200_000, "1.2M tokens"), (2000, "2k tokens")])
    func tokens(count: Int, text: String) {
        #expect(DelegationText.tokens(count) == text)
    }

    @Test("subagent 卡的說明行：類型 · 模型，與「1m 6s · 21.5k tokens · 6 tool calls」")
    func subagentLines() {
        let card = SubagentCard(id: "c", callID: "t", title: "Check", agentType: "general-purpose", model: "sonnet",
                                status: .completed, duration: 66, tokens: 21500, toolCalls: 6)
        #expect(DelegationText.subtitle(of: card) == "general-purpose · sonnet")
        #expect(DelegationText.stats(of: card) == "1m 6s · 21.5k tokens · 6 tool calls")
        let one = SubagentCard(id: "c", callID: "t", title: "Check", status: .completed, toolCalls: 1)
        #expect(DelegationText.stats(of: one) == "1 tool call")
        #expect(DelegationText.subtitle(of: one) == nil)
    }

    @Test("workflow 卡：執行中「2 of 3 agents done」,結束後「3 agents」,還不知道 agent 時沒有")
    func workflowProgress() {
        let agents = [
            WorkflowAgent(agentID: "a1", label: "a", state: .completed), WorkflowAgent(agentID: "a2", label: "b", state: .completed),
            WorkflowAgent(agentID: "a3", label: "c", state: .running),
        ]
        let running = WorkflowRun(isRunning: true, phases: [WorkflowPhase(title: "P", agents: agents)])
        #expect(DelegationText.progress(of: running) == "2 of 3 agents done")
        var done = running
        done.isRunning = false
        done.phases[0].agents[2].state = .completed
        #expect(DelegationText.progress(of: done) == "3 agents")
        #expect(DelegationText.progress(of: WorkflowRun(isRunning: true)) == nil)
    }

    static func pane(_ states: [DelegationStatus], elapsed: [Int]? = nil, hidden: Int = 0) -> AgentsPane {
        AgentsPane(rows: states.enumerated().map { index, state in
            AgentsPane.Row(id: index, state: state, kind: "general-purpose", task: "t\(index)", elapsedSeconds: elapsed?[index] ?? 10, tokens: 100)
        }, hiddenCount: hidden)
    }

    @Test("背景 agents 列摘要：工作中「N agents working · 最長經過時間」(經過時間含讀取後經過的秒數)")
    func barSummaryWorking() {
        let pane = Self.pane([.running, .completed, .running], elapsed: [100, 9000, 3600])
        #expect(DelegationText.summary(of: pane, secondsSinceRead: 20) == "2 agents working · 1h 0m")
    }

    @Test("全部完成且沒有藏在折疊下的列才說「N agents done」;有失敗是「N done · M failed」;有隱藏列加「K more in the terminal」")
    func barSummaryFinished() {
        #expect(DelegationText.summary(of: Self.pane([.completed, .completed]), secondsSinceRead: 0) == "2 agents done")
        #expect(DelegationText.summary(of: Self.pane([.completed, .failed]), secondsSinceRead: 0) == "1 done · 1 failed")
        #expect(DelegationText.summary(of: Self.pane([.completed, .completed], hidden: 4), secondsSinceRead: 0) == "2 done · 4 more in the terminal")
        #expect(DelegationText.summary(of: Self.pane([.running], hidden: 4), secondsSinceRead: 0) == "1 agent working · 10s · 4 more in the terminal")
    }

    @Test("背景 agents 列的種類：general-purpose → General、fork → Fork、其他照原名")
    func kindNames() {
        #expect(DelegationText.kind("general-purpose") == "General")
        #expect(DelegationText.kind("fork") == "Fork")
        #expect(DelegationText.kind("code-reviewer") == "code-reviewer")
    }

    @Test("列的經過時間每秒前進(畫面值 + 讀取後經過);完成列停止")
    func rowElapsedAdvances() {
        let pane = Self.pane([.running, .completed], elapsed: [60, 60])
        #expect(DelegationText.elapsed(of: pane.rows[0], secondsSinceRead: 6) == "1m 6s")
        #expect(DelegationText.elapsed(of: pane.rows[1], secondsSinceRead: 6) == "1m 0s")
    }
}
