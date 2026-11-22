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

    /// 方案用量來源(經主機通道):Claude 讀包裝腳本存下的用量(要經同意寫主機),Codex 執行一次 `codex app-server`。
    package func planUsage(for agent: AgentID, ssh context: SSHContext) -> PlanUsageSource? {
        switch agent {
        case .claude:
            .claude(channel: context.channel, files: context.files, cost: context.cost, hostID: context.hostID, consent: context.consent)
        case .codex:
            .codex(channel: context.channel, cost: context.cost)
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

extension PlanUsageAgent {
    /// 對應的 Agent 種類。
    package var agentID: AgentID {
        switch self {
        case .claudeCode: .claude
        case .codex: .codex
        }
    }
}
