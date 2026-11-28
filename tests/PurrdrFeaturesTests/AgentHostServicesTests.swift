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

    @Test("方案用量:Claude 與 Antigravity 要經同意寫主機,Codex 不寫主機,其他種類沒有來源")
    func planUsageSources() {
        #expect(services.planUsage(for: .claude, ssh: context)?.hostWrite != nil)
        #expect(services.planUsage(for: .codex, ssh: context) != nil)
        #expect(services.planUsage(for: .codex, ssh: context)?.hostWrite == nil)
        #expect(services.planUsage(for: .agy, ssh: context)?.hostWrite != nil)
        #expect(services.planUsage(for: .grok, ssh: context) == nil)
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

    @Test("方案用量 Agent 與 planUsageKey 互相對應(維持舊識別碼)")
    func planUsageKeys() {
        #expect(AgentID.claude.planUsageKey == "claudeCode")
        #expect(AgentID.agy.planUsageKey == "antigravity")
        #expect(AgentID.codex.planUsageKey == "codex")
        for agent in AgentHostCapabilities.planUsageAgents {
            #expect(AgentID(planUsageKey: agent.planUsageKey) == agent)
        }
        #expect(AgentID(planUsageKey: "grok") == nil)
    }

    /// 每個 Agent × 連線方式一列(風格同 `TranscriptDialectContractTests`):預期的能力,與實際接線一致。
    struct Row: Sendable, CustomTestStringConvertible {
        var agent: AgentID
        var connection: AgentHostConnectionKind
        var expected: AgentHostCapabilities
        var testDescription: String { "\(agent.canonicalName) over \(connection)" }
    }

    nonisolated static let rows: [Row] = {
        func caps(_ usage: Bool, _ writes: Bool, _ status: Bool, _ slash: Bool, _ launcher: Bool) -> AgentHostCapabilities {
            AgentHostCapabilities(planUsage: usage, planUsageWritesHost: writes, sessionStatus: status, slashDiscovery: slash, launcher: launcher)
        }
        var rows: [Row] = []
        for connection in AgentHostConnectionKind.allCases {
            let ssh = connection != .https
            rows.append(Row(agent: .claude, connection: connection, expected: caps(true, true, true, true, false)))
            rows.append(Row(agent: .codex, connection: connection, expected: caps(true, false, false, false, ssh)))
            rows.append(Row(agent: .agy, connection: connection, expected: caps(ssh, ssh, ssh, false, false)))
            for other in [AgentID.grok, .gemini, .other("x")] {
                rows.append(Row(agent: other, connection: connection, expected: .none))
            }
        }
        return rows
    }()

    @Test("能力表逐列", arguments: rows)
    func capabilityTable(row: Row) {
        #expect(AgentHostCapabilities.resolve(row.agent, over: row.connection) == row.expected)
    }

    @Test("SSH 接線與能力表一致:方案用量、slash、啟動器", arguments: rows.filter { $0.connection == .ssh })
    func sshWiringMatchesTable(row: Row) {
        let caps = AgentHostCapabilities.resolve(row.agent, over: .ssh)
        let source = services.planUsage(for: row.agent, ssh: context)
        #expect((source != nil) == caps.planUsage)
        #expect((source?.hostWrite != nil) == caps.planUsageWritesHost)
        #expect((services.slashDiscovery(for: row.agent, channel: FakeHost()) != nil) == caps.slashDiscovery)
        #expect((services.launcher(for: row.agent, channel: FakeHost(), hostID: "h", consent: consent) != nil) == caps.launcher)
    }
}
#endif
