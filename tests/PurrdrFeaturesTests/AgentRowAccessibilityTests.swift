import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// Agents 列的 VoiceOver 句子(#269,spec #267 故事 14):依序念 agent 種類、workspace、狀態、主機與最後一句、時間。
@MainActor
@Suite("Agents 列的 VoiceOver")
struct AgentRowAccessibilityTests {
    @Test("依序是 agent、workspace、狀態、主機 · 最後一句、時間")
    func sentenceOrder() {
        let row = AgentRow(
            paneID: "w1:p1", kind: "claude", title: "Tidy up the CSV export", workspace: "ledger", subtitle: "",
            preview: .message("Done. The export now writes date.", fromYou: false), time: .now, status: .done)

        #expect(AgentRowView.accessibilityText(row, host: HostLabel(name: "Demo", icon: .default))
            == "Claude Code, ledger, Done, Demo · Done. The export now writes date., Now")
    }

    @Test("需要你：預覽是等你回覆;釘選與靜音接在狀態之後")
    func needsYouPinnedMuted() {
        let row = AgentRow(
            paneID: "w2:p1", kind: "codex", title: "t", workspace: "weather-app", subtitle: "",
            preview: .needsInput, time: nil, status: .blocked, isPinned: true, isMuted: true)

        #expect(AgentRowView.accessibilityText(row, host: HostLabel(name: "Demo", icon: .default))
            == "Codex, weather-app, Needs You, Pinned, Muted, Demo · Waiting for your input")
    }
}
