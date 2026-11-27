import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 主機能力對照表(#443、ADR-0013):依 Agent 種類接上「要連主機」的能力——方案用量來源、slash 探索、啟動器。
/// 這些不放進 Agent 設定檔(設定檔是可攜核心的純值),所以由 Features 在這裡對照;`HostsModel` 不再自己依種類切換。
/// 沒有的種類回 `nil`,畫面自然隱藏。HTTPS 主機照舊不提供 SSH 專屬能力(`SSHContext` 只在 SSH 與 Demo 主機建立)。
package struct AgentHostServices {
    /// SSH 主機(或 Demo 主機)上建方案用量來源所需的東西。
    package struct SSHContext {
        package var channel: any HostChannel
        package var files: HostFiles?
        package var cost: PlanUsageQueryCost
        package var hostID: String
        package var consent: any HostWriteConsentStore

        package init(channel: any HostChannel, files: HostFiles?, cost: PlanUsageQueryCost, hostID: String, consent: any HostWriteConsentStore) {
            self.channel = channel
            self.files = files
            self.cost = cost
            self.hostID = hostID
            self.consent = consent
        }
    }

    package init() {}

    /// 方案用量來源(經主機通道):Claude 與 Antigravity 讀包裝腳本存下的用量(要經同意寫主機),Codex 執行一次 `codex app-server`。
    package func planUsage(for agent: AgentID, ssh context: SSHContext) -> PlanUsageSource? {
        switch agent {
        case .claude:
            .claude(channel: context.channel, files: context.files, cost: context.cost, hostID: context.hostID, consent: context.consent)
        case .codex:
            .codex(channel: context.channel, cost: context.cost)
        case .agy:
            .antigravity(channel: context.channel, files: context.files, cost: context.cost, hostID: context.hostID, consent: context.consent)
        default:
            nil
        }
    }

    /// 在主機上發現 slash 清單的探索器:只有 Claude(Codex、Grok、Antigravity 用設定檔的固定清單)。
    package func slashDiscovery(for agent: AgentID, channel: any HostChannel) -> (any SlashDiscovering)? {
        agent == .claude ? ClaudeSlashDiscovery(channel: channel) : nil
    }

    /// 啟動器(Session 回報的主機端設定):只有 Codex。
    @MainActor
    package func launcher(for agent: AgentID, channel: any HostChannel, hostID: String, consent: any HostWriteConsentStore) -> CodexLauncherModel? {
        agent == .codex ? CodexLauncherModel(host: CodexLauncherHost(channel: channel), hostID: hostID, consent: consent) : nil
    }
}

/// 主機連線方式:能力表的第二個鍵(Demo 主機的通道是 Demo,走 SSH 的程式路徑)。
package enum AgentHostConnectionKind: CaseIterable, Sendable {
    case ssh, https, demo
}

/// 一種 Agent 在一種連線方式下,app 能對主機做哪些事(#686、ADR-0013)。
/// 沒有的能力是 `false`/`nil`,畫面自然隱藏;新增 Agent 或連線方式只改 `resolve` 這一張表,
/// `AgentHostCapabilitiesTests` 逐列檢查。
package struct AgentHostCapabilities: Equatable, Sendable {
    /// 讀得到方案用量。
    package var planUsage: Bool
    /// 方案用量要先經同意修改主機設定(status line 包裝腳本)。
    package var planUsageWritesHost: Bool
    /// 讀得到 session 狀態(context 用量)。
    package var sessionStatus: Bool
    /// 在主機上發現 slash 清單。
    package var slashDiscovery: Bool
    /// 有啟動器(Session 回報的主機端設定)。
    package var launcher: Bool

    package init(planUsage: Bool, planUsageWritesHost: Bool, sessionStatus: Bool, slashDiscovery: Bool, launcher: Bool) {
        self.planUsage = planUsage
        self.planUsageWritesHost = planUsageWritesHost
        self.sessionStatus = sessionStatus
        self.slashDiscovery = slashDiscovery
        self.launcher = launcher
    }

    package static let none = AgentHostCapabilities(
        planUsage: false, planUsageWritesHost: false, sessionStatus: false, slashDiscovery: false, launcher: false)

    /// 方案用量畫面列出的 Agent(依畫面順序)。
    package static let planUsageAgents: [AgentID] = [.claude, .codex, .agy]

    package static func resolve(_ agent: AgentID, over connection: AgentHostConnectionKind) -> AgentHostCapabilities {
        let overSSH = connection != .https
        switch agent {
        case .claude:
            return AgentHostCapabilities(
                planUsage: true, planUsageWritesHost: true, sessionStatus: true, slashDiscovery: overSSH, launcher: false)
        case .codex:
            return AgentHostCapabilities(
                planUsage: true, planUsageWritesHost: false, sessionStatus: false, slashDiscovery: false, launcher: overSSH)
        case .agy:
            // Antigravity 的 statusline 包裝只有 SSH(#448)。
            return AgentHostCapabilities(
                planUsage: overSSH, planUsageWritesHost: overSSH, sessionStatus: overSSH, slashDiscovery: false, launcher: false)
        default:
            return .none
        }
    }
}

extension AgentID {
    /// 方案用量畫面的穩定鍵(儲存的選擇與 UI 測試識別碼用,維持舊 `PlanUsageAgent` 的值)。
    package var planUsageKey: String {
        switch self {
        case .claude: "claudeCode"
        case .agy: "antigravity"
        default: canonicalName
        }
    }

    package init?(planUsageKey: String) {
        guard let agent = AgentCatalogKeys.agents.first(where: { $0.planUsageKey == planUsageKey }) else { return nil }
        self = agent
    }
}

private enum AgentCatalogKeys {
    static let agents = AgentHostCapabilities.planUsageAgents
}
