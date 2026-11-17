import Foundation
import PurrdrCore

/// Subagent／workflow 卡片與背景 agents 列的文字(行為規格 F10)。顯示文字經 String Catalog 翻譯;單位縮寫(s、m、h、k、M)不翻。
package enum DelegationText {
    /// 「<1s / 48s / 1m 6s / 1h 2m」。
    package static func duration(_ seconds: Double) -> String {
        guard seconds >= 1 else { return "<1s" }
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }

    /// 「940 / 21.5k / 1.2M tokens」。
    package static func tokens(_ count: Int) -> String {
        String(localized: "\(compact(count)) tokens")
    }

    package static func compact(_ count: Int) -> String {
        func oneDecimal(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        }
        if count < 1000 { return String(count) }
        if count < 1_000_000 { return oneDecimal(Double(count) / 1000) + "k" }
        return oneDecimal(Double(count) / 1_000_000) + "M"
    }

    package static func toolCalls(_ count: Int) -> String {
        count == 1 ? String(localized: "1 tool call") : String(localized: "\(count) tool calls")
    }

    /// 「subagent_type · 模型」;完整的 Claude 模型 id 顯示成「Sonnet 5.5」這類名稱。
    package static func subtitle(of card: SubagentCard) -> String? {
        let model = card.model.map { $0.hasPrefix("claude-") ? TranscriptMetadata.displayName(ofModel: $0) : $0 }
        let parts = [card.agentType, model].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 「1m 6s · 21.5k tokens · 6 tool calls」(沒有的項目略過)。
    package static func stats(of card: SubagentCard) -> String {
        [card.duration.map(duration), card.tokens.map(tokens), card.toolCalls.map(toolCalls)].compactMap { $0 }.joined(separator: " · ")
    }

    package static func stats(of card: WorkflowCard, run: WorkflowRun?) -> String {
        let seconds = card.duration ?? run?.durationMs.map { Double($0) / 1000 }
        let count = card.tokens ?? run?.totalTokens
        return [seconds.map(duration), count.map(tokens)].compactMap { $0 }.joined(separator: " · ")
    }

    /// 執行中「2 of 3 agents done」;結束後「3 agents」;還不知道有哪些 agent 時沒有。
    package static func progress(of run: WorkflowRun) -> String? {
        let total = run.agents.count
        guard total > 0 else { return nil }
        if run.isRunning || run.agents.contains(where: { $0.state == .running }) {
            return String(localized: "\(run.completedAgents) of \(total) agents done")
        }
        return total == 1 ? String(localized: "1 agent") : String(localized: "\(total) agents")
    }

    package static func workflowAgentStats(_ agent: WorkflowAgent) -> String {
        [agent.durationMs.map { duration(Double($0) / 1000) }, agent.tokens.map(tokens), agent.toolCalls.map(toolCalls)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - 背景 agents 列

    /// 收合摘要(F10):工作中「N agents working · 最長經過時間」;全部完成且沒有藏在折疊下的列才說「N agents done」;
    /// 其他「N done · M failed」;有隱藏列加「K more in the terminal」。
    package static func summary(of pane: AgentsPane, secondsSinceRead: Double) -> String {
        let running = pane.rows.filter { $0.state == .running }
        let failed = pane.rows.count { $0.state == .failed }
        let done = pane.rows.count { $0.state == .completed }
        var parts: [String] = []
        if !running.isEmpty {
            let longest = running.map { Double($0.elapsedSeconds) + secondsSinceRead }.max() ?? 0
            parts = [running.count == 1 ? String(localized: "1 agent working") : String(localized: "\(running.count) agents working"), duration(longest)]
        } else if failed == 0, pane.hiddenCount == 0 {
            parts = [done == 1 ? String(localized: "1 agent done") : String(localized: "\(done) agents done")]
        } else {
            parts = [String(localized: "\(done) done")]
            if failed > 0 { parts.append(String(localized: "\(failed) failed")) }
        }
        if pane.hiddenCount > 0 { parts.append(String(localized: "\(pane.hiddenCount) more in the terminal")) }
        return parts.joined(separator: " · ")
    }

    /// 種類：`general-purpose` → General、`fork` → Fork,其他照原名。
    package static func kind(_ kind: String) -> String {
        switch kind.lowercased() {
        case "general-purpose", "general": String(localized: "General")
        case "fork": String(localized: "Fork")
        default: kind
        }
    }

    /// 列的經過時間：執行中的列 = 畫面值 + 讀取後經過的秒數;完成列停止。
    package static func elapsed(of row: AgentsPane.Row, secondsSinceRead: Double) -> String {
        duration(Double(row.elapsedSeconds) + (row.state == .running ? secondsSinceRead : 0))
    }
}
