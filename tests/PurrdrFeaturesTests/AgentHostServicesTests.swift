#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 主機能力對照表(#443):依 Agent 種類接上方案用量、slash 探索、啟動器;沒有的種類回 `nil`,畫面自然隱藏。
@MainActor
@Suite("主機能力對照表 AgentHostServices")
struct AgentHostServicesTests {
    let services = AgentHostServices()
    let consent = InMemoryHostWriteConsentStore()

    var context: AgentHostServices.SSHContext {
        AgentHostServices.SSHContext(channel: FakeHost(), files: nil, cost: .transfer, hostID: "host-1", consent: consent)
    }

    @Test("方案用量:Claude 要經同意寫主機,Codex 不寫主機,其他種類沒有來源")
    func planUsageSources() {
        #expect(services.planUsage(for: .claude, ssh: context)?.hostWrite != nil)
        #expect(services.planUsage(for: .codex, ssh: context) != nil)
        #expect(services.planUsage(for: .codex, ssh: context)?.hostWrite == nil)
        #expect(services.planUsage(for: .agy, ssh: context) == nil)
        #expect(services.planUsage(for: .other("x"), ssh: context) == nil)
    }

    @Test("方案用量:來源的費用沿用連線方式")
    func planUsageCost() {
        #expect(services.planUsage(for: .claude, ssh: context)?.cost == .transfer)
        #expect(services.planUsage(for: .codex, ssh: context)?.cost == .transfer)
    }

    @Test("slash 探索:只有 Claude 在主機上發現")
    func slashDiscovery() {
        #expect(services.slashDiscovery(for: .claude, channel: FakeHost()) != nil)
        #expect(services.slashDiscovery(for: .codex, channel: FakeHost()) == nil)
        #expect(services.slashDiscovery(for: .agy, channel: FakeHost()) == nil)
    }

    @Test("啟動器:只有 Codex")
    func launcher() {
        #expect(services.launcher(for: .codex, channel: FakeHost(), hostID: "h", consent: consent) != nil)
        #expect(services.launcher(for: .claude, channel: FakeHost(), hostID: "h", consent: consent) == nil)
    }

    @Test("PlanUsageAgent 與 Agent 種類互相對應")
    func planUsageAgentMapping() {
        #expect(PlanUsageAgent.claudeCode.agentID == .claude)
        #expect(PlanUsageAgent.codex.agentID == .codex)
    }
}
#endif
